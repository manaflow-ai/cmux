# Cloud area card: backend/, workers/, services/, web/

New Cloud backend code goes to the private manaflow-ai/cmux-platform repo. A fix to code still here (the paths in
`.github/cloud-backend-paths.json`) needs a PR description line starting `cmux-platform:`; `pr-cloud-backend-check`
warns without it. Read [skills/cmux-backend/SKILL.md](../skills/cmux-backend/SKILL.md) first.

## Where things live

- `backend/apps/api`: the cmux-next API Worker (Cloudflare, Durable Objects). HTTP paths are dispatched in `src/index.ts`, handlers sit in `src/*-routes.ts` and `src/domains/`.
- `backend/packages/protocol`: Cloud wire ops in Effect Schema (`src/ops.ts`); generates `backend/catalog/*.json`, `clients/ts/cloud` and the Rust `cmux-cloud-wire` types.
- `backend/db`: Postgres `cmux-next` schema (`schema/index.ts`), migrations (`migrations/NNNN_*.sql`), Drizzle snapshots (`drizzle/`), MySQL/Vitess track (`drizzle-mysql/`, `migrate-mysql.ts`).
- `backend/apps/dashboard`: the Cloud console (Vite, TanStack Router). `backend/apps/home-server`: the self-hosted chat server. `backend/packages/ownership`, `saml`, `home-core`: libraries. `backend/chief-cc`, `chief-opencode`: Chief VM images.
- `web/`: Next.js site and the old Cloud VM backend: routes in `web/app/api`, logic in `web/services`, DB `cmux-prod` in `web/db`. Read [web/AGENTS.md](../web/AGENTS.md).
- `workers/cmux-vm`: the cmux VM API Worker, own migrations (`migrations/`), contract in `src/api.ts` and `openapi.json`. `cli/` and `sdk/` are client code.
- `workers/device-hub`, `iroh-v2`, `presence`: Cloud Workers. `services/iroh-relay-minter`: Rust relay minter.
- Not Cloud product: `workers/ci-artifacts`, `fleet-artifacts`, `cmux-actions` (CI infra); `services/conversation-sim` (fake chat service); `server/prototype/linux` (server install prototype).

A new API route: op in `backend/packages/protocol/src`, handler in `backend/apps/api/src`, test in `backend/apps/api/test`.
A Postgres migration: follow [skills/cmux-backend-migrations](../skills/cmux-backend-migrations/SKILL.md) exactly; a new
Durable Object class goes in `migrations` of `apps/api/wrangler.jsonc`. A web page or old VM route: `web/app/`; a
`web/db` migration: edit `web/db/schema.ts`, then `bun run db:generate` in `web/`.

## Test in five minutes

Needs bun 1.4.4 (as `backend.yml`), Docker for database steps, and `bun install --frozen-lockfile` once in `backend/`
(it also covers `clients/ts/*` and `workers/cmux-vm/sdk`), `web/` or the worker you touch.

Fast enough for a 2-core VM (one file or one package; each line starts at the repo root):

```bash
cd backend/apps/api && bun run test test/server-pairing.test.ts   # one file, vitest on workerd; also packages/*
cd backend/apps/api && bun run typecheck                    # tsc for one package; `bun run typecheck` in backend/ runs all
cd backend && bun run catalog:check && bun run lint:size    # generated catalog drift, 1000-line/64 KB file limit
cd backend/db && bun migrate.ts --lint && bun test test     # parsed-SQL migration lint
cd scripts/cmux-next/release && bun install --frozen-lockfile && bun lint.ts --tree backend   # or --tree cmux-vm
cd web && bun run test tests/account-route.test.ts && bun run typecheck && bun run lint:complexity
scripts/web-lint.sh                                          # ESLint on the web/ files you changed
cd workers/cmux-vm && bun run typecheck && bun run lint && bun run openapi:check
```

Leave to CI: the full `backend/apps/api` suite (`bun run test`, `test:node`), migrations
from zero plus `bun test test-pg` / `test-mysql` (scratch Postgres 17, MySQL 8.4 via `backend/db/scripts/mysql-scratch.sh up`),
the dashboard build, `bun run vercel-build`, all web tests (`bun run test` with no file), `bun run check` in `workers/cmux-vm`.

## Local loop

- API Worker, unmerged: `scripts/cmux-next/cloud-dev-stack.sh up --tag <slug>` (`down --tag <slug>` after). Details: skills/cmux-backend "Run your unmerged cmux-next API". `bun run dev` in `backend/apps/api` is `wrangler dev --env development`; in `backend/apps/dashboard` it serves port 3010.
- `web/`: `bun dev` on Linux starts this worktree's Docker Postgres, migrates it and runs Next on `CMUX_PORT` (default 3777); `bun db:up`, `db:migrate`, `db:test`, `db:reset`, `db:down` ([web/README.md](../web/README.md)). No seed script exists.
- Secrets: `~/.secrets/cmux.env` and `~/.secrets/cmuxterm-dev.env` (skills/cmux-backend "Secrets").

## What CI gates a Cloud PR

- `backend` (`.github/workflows/backend.yml`), job `test`: install, typecheck, catalog drift, lint:size, migration lints, migrations from zero, every package's tests, dashboard build, wrangler dry run. Then `migrations-development`, `preview`, `journey-preview`. `backend-migrations` job `gate` posts the required `backend migrations applied`.
- `CI`, job `web` (calls `ci-web.yml`): `web-typecheck`, `Web tests (N)`, `web-db-migrations`, `web-production-build`, `Web status`. Plus `Web complexity` (`web-complexity-trusted.yml`) and `Billing` for billing paths.
- `cmux VM` job `check`, `device-hub` job `test`, `IROH v2` job `backend`, `cmux VM Cloud adapter`, `cmux VM clients`, `Cloud CLI` (catalog changes). `presence` and `Iroh relay minter` are dispatch only.

Common mechanical reds and their fix:
- `bun install --frozen-lockfile` fails: run `bun install` in the dir that owns the `bun.lock` and commit it.
- "Catalog and generated client drift": in `backend/`, run `bun run catalog:export`, `catalog:client`, `catalog:rust` (vectors: `catalog:vectors`, `catalog:link-vectors`, `mirror:vectors` in their packages) and commit the output.
- "No god files": split the file by owner or domain (`backend/scripts/check-file-size.ts`); never squeeze lines.
- Release rails lint, "hash lock": `bun lint.ts --update-lock --tree backend` in `scripts/cmux-next/release`, commit `migrations.lock.json`.
- `test-pg/drizzle-schema.test.ts`: `bun run db:generate` in `backend/db`, commit the snapshot in `drizzle/`.
- `backend migrations applied` red: add the label `backend:apply-migrations`; re-add it after every push that changes SQL.
- Push refused by `scripts/check-backend-migration-flow.py` (run by `scripts/verify-local.py`): open the PR first, or set `CMUX_BACKEND_MIGRATION_PR=1`.
- `openapi.json matches the HttpApi definition`: `bun run openapi` in `workers/cmux-vm`.
- Web complexity: lower the function's complexity; never add baseline lines ([web/AGENTS.md](../web/AGENTS.md)).

Deeper docs: [docs/backend-migrations.md](../docs/backend-migrations.md), [docs/cloud-guest-upgrades.md](../docs/cloud-guest-upgrades.md), [skills/cmux-backend/references/](../skills/cmux-backend/references/),
[skills/cmux-cloud-vm/SKILL.md](../skills/cmux-cloud-vm/SKILL.md), [workers/cmux-vm/README.md](../workers/cmux-vm/README.md), [backend/db/drizzle/README.md](db/drizzle/README.md),
[skills/cmux-testing/references/pr-ci-coverage.md](../skills/cmux-testing/references/pr-ci-coverage.md).
