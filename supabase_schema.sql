-- =====================================================================
--  APROVA PCBA — Esquema PostgreSQL / Supabase com Row Level Security
--  Modelo de produção correspondente ao app (mesmas regras de negócio).
--  Cada registro: UUID, created_at, updated_at, owner (auth.uid()).
--  A lógica do motor de reprogramação e da revisão espaçada vive na
--  aplicação; o banco garante integridade, propriedade e isolamento.
-- =====================================================================

create extension if not exists "pgcrypto";

-- gatilho utilitário: mantém updated_at
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------------------------------------------------------------------
-- 1. CONCURSO  (PCBA, INEMA, SEMA … arquitetura multi-concurso)
-- ---------------------------------------------------------------------
create table concurso (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nome         text not null,
  banca        text,
  prova_date   date,
  cap_dia      int  not null default 215,
  meta_aprov   int  not null default 80,
  ref_date     date,
  blocos       jsonb not null default '[{"id":"A","ini":"04:00","fim":"05:20","min":80},
                                        {"id":"B","ini":"05:35","fim":"06:55","min":80},
                                        {"id":"C","ini":"07:05","fim":"08:00","min":55}]',
  rev_dur      jsonb not null default '{"D1":20,"D7":30,"D30":35}',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. EDITAL_ITEM  (aba "Cobertura do Edital")
-- ---------------------------------------------------------------------
create table edital_item (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  bloco         text,
  disciplina    text not null,
  item          text not null,
  conteudo      text,
  prioridade    text check (prioridade in ('MÁXIMA. AOCP','ALTA','MÉDIA','BAIXA')),
  dicas_diretas int default 0, dicas_parciais int default 0,
  dicas_comp    int default 0, dicas_correlatas int default 0,
  situacao      text, lacuna text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. DICA  (unidade atômica — aba "Cruzamento Dicas Edital")
--    Título integral preservado; vínculo exato ao item do edital.
-- ---------------------------------------------------------------------
create table dica (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  codigo        text not null,                 -- ex.: LP-001
  caderno       text, disciplina text, item text,
  titulo        text not null,                 -- título integral, NUNCA reduzido
  pagina        text,
  prioridade    text, aderencia text check (aderencia in ('Direta','Parcial','Complementar','Correlato','Fora do edital')),
  -- progresso do usuário
  status        text not null default 'Não iniciado'
                check (status in ('Não iniciado','Em andamento','Concluído','Adiado','Dispensado')),
  dominio       int check (dominio between 0 and 5),
  questoes      int default 0, acertos int default 0,
  obs           text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (concurso_id, codigo)
);

-- ---------------------------------------------------------------------
-- 4. BLOCO_PLANO  (aba "Plano Diário Detalhado" — seg a sex, blocos A/B/C)
-- ---------------------------------------------------------------------
create table bloco_plano (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  data_prevista date not null,
  data_movida   date,                          -- definida pelo motor de reprogramação
  dia_semana    text, semana int, fase text,
  bloco         text check (bloco in ('A','B','C')),
  inicio        text, fim text, minutos int not null,
  caderno       text, disciplina text, item text,
  codigos_dicas text[],                         -- referências às dicas
  metodo        text, prioridade text,
  status        text not null default 'Não iniciado'
                check (status in ('Não iniciado','Em andamento','Concluído','Adiado','Dispensado')),
  horas_reais   numeric, questoes int default 0, acertos int default 0,
  dominio       int check (dominio between 0 and 5),
  data_real     date, obs text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on bloco_plano (concurso_id, data_prevista);
create index on bloco_plano (concurso_id, status);

-- ---------------------------------------------------------------------
-- 5. ATIVIDADE_FDS  (aba "Fins de Semana" — sáb revisão/discursiva, dom simulado)
-- ---------------------------------------------------------------------
create table atividade_fds (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  data          date not null, dia_semana text, semana int,
  tipo          text, inicio text, fim text, minutos int,
  foco          text, tarefa text, meta_questoes int default 0,
  status        text not null default 'Não iniciado'
                check (status in ('Não iniciado','Em andamento','Concluído','Adiado','Dispensado')),
  horas_reais   numeric, questoes int default 0, acertos int default 0,
  nota_discursiva numeric, obs text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. REVISAO  (revisão espaçada D+1 / D+7 / D+30)
-- ---------------------------------------------------------------------
create table revisao (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  bloco_id      uuid references bloco_plano(id) on delete cascade,
  dica_id       uuid references dica(id) on delete cascade,
  tipo          text not null check (tipo in ('D1','D7','D30')),
  data_prevista date not null, data_realizada date, data_movida date,
  status        text not null default 'Pendente'
                check (status in ('Pendente','Concluída no prazo','Concluída com atraso','Adiada','Dispensada')),
  duracao       int, questoes int default 0, acertos int default 0,
  dominio_antes int check (dominio_antes between 0 and 5),
  dominio_depois int check (dominio_depois between 0 and 5),
  vinculo_erros text, obs text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (bloco_id is not null or dica_id is not null)
);
create index on revisao (concurso_id, status, data_prevista);

-- ---------------------------------------------------------------------
-- 7. BLOQUEIO  (férias, feriados, indisponibilidades, consultas)
-- ---------------------------------------------------------------------
create table bloqueio (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concurso_id   uuid not null references concurso(id) on delete cascade,
  data          date not null, motivo text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- gatilhos updated_at
-- ---------------------------------------------------------------------
do $$ declare t text;
begin
  foreach t in array array['concurso','edital_item','dica','bloco_plano','atividade_fds','revisao','bloqueio']
  loop
    execute format('create trigger trg_%1$s_upd before update on %1$s
                    for each row execute function set_updated_at();', t);
  end loop;
end $$;

-- =====================================================================
--  ROW LEVEL SECURITY — cada usuário só enxerga e altera o que é seu
-- =====================================================================
do $$ declare t text;
begin
  foreach t in array array['concurso','edital_item','dica','bloco_plano','atividade_fds','revisao','bloqueio']
  loop
    execute format('alter table %I enable row level security;', t);
    execute format($p$create policy %1$s_sel on %1$s for select using (owner = auth.uid());$p$, t);
    execute format($p$create policy %1$s_ins on %1$s for insert with check (owner = auth.uid());$p$, t);
    execute format($p$create policy %1$s_upd on %1$s for update using (owner = auth.uid()) with check (owner = auth.uid());$p$, t);
    execute format($p$create policy %1$s_del on %1$s for delete using (owner = auth.uid());$p$, t);
  end loop;
end $$;

-- =====================================================================
--  VIEW de apoio ao motor: fila priorizada (mesma ordem do app)
--  1 rev. vencida dom1-2 · 2 rev. vencida <80% · 3 MÁXIMA · 4 ALTA
--  5 pendência da semana · 6 MÉDIA · 7 parcial/correlato · 8 complementar
-- =====================================================================
create or replace view v_fila_estudos as
select b.id, b.concurso_id, b.owner, 'bloco'::text as tipo,
  coalesce(b.data_movida,b.data_prevista) as data, b.minutos, b.caderno as rotulo,
  case
    when b.prioridade='MÁXIMA. AOCP' then 3
    when b.prioridade='ALTA' then 4
    when b.prioridade='MÉDIA' then 6
    else 8
  end as tier
from bloco_plano b
where b.status not in ('Concluído','Dispensado')
order by tier, data;
