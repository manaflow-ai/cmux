# cmux-mobile-api

Cloudflare Worker for the cmux-next-ios app. It implements the HTTP and signaling
parts of [`../PROTOCOL.md`](../PROTOCOL.md), which is the contract.

- `src/index.ts`: routes, Stack JWT auth, validation.
- `src/team-hub.ts`: `TeamHub` Durable Object, one per **user** (named
  `user:<owner key>` from the verified token; SQLite-backed, hibernating
  WebSockets): signaling admission, Mac presence of the user's own devices
  (no data relay: WireGuard without UDP uses TURN over TLS), 60 s membership
  cache. A hub binds its owner on first use and refuses calls for another.
  Teammates never share a hub (PROTOCOL.md "Signaling WebSocket"). A hub is
  created with a `locationHint` from the caller's geolocation
  (`locationHintFor` in `src/index.ts`), since a hub never moves and
  free-plan requests are sometimes received in a far colo.
  `GET /v1/teams/:teamId/hub` reports the ingress colo and the hub's colo.
- `src/store.ts`, `src/schema.ts`, `drizzle/`: PlanetScale Postgres through
  Hyperdrive (Drizzle). Tests use an in-memory store.
- `src/stack.ts`: Stack team membership and invitations.
- `src/ice.ts`: Cloudflare Realtime TURN credentials (1 h TTL; `turn:false` in the answer when none could be included).
- `src/push.ts`: APNs sender for `POST /v1/devices/:deviceId/notify` (fixed text per event kind; never agent output).
- Rate limits: Workers rate limiting bindings per env (`ratelimits` in `wrangler.jsonc`), keyed by the caller's owner key (the Mac for notify). Tests run without them.

## Environments

| Env | Worker | URL | Database |
| --- | --- | --- | --- |
| `dev` | `cmux-mobile-api-dev` | https://cmux-mobile-api-dev.debussy.workers.dev | PlanetScale Postgres `cmux/cmux-mobile-dev`, branch `main`, role `cmux-mobile-api`, Hyperdrive `cmux-mobile-dev` (`e4fd2e88cfcd4f00841ddc5b49c3ee06`, caching disabled) |
| `prod` | `cmux-mobile-api-prod` | https://mobile-api.cmux.dev (custom domain; also https://cmux-mobile-api-prod.debussy.workers.dev) | PlanetScale Postgres `cmux/cmux-mobile-prod` (its own database, single node, us-east), branch `main`, role `cmux-mobile-api`, Hyperdrive `cmux-mobile-prod` (`11158756425f41469964743aab2f6319`, caching disabled). Accepts only the production Stack project |

### Resource names

Production naming (2026-10-20). "cnx" was a development tag; nothing ships under it.
Durable Object namespaces carry the name the Worker had when the namespace was created
(`<worker>_TeamHub`); Cloudflare keeps that label when a Worker is renamed and it is
never shown to anyone. The class itself is `TeamHub`.

| Resource | Before | Now |
| --- | --- | --- |
| Dev Worker | `cnx-ios-api-dev` | `cmux-mobile-api-dev` (renamed in place: same script id, secrets and hub namespace) |
| Prod Worker | `cnx-ios-api-prod` | `cmux-mobile-api-prod` (renamed in place) |
| Prod host | `cnx-ios-api.cmux.dev` | `mobile-api.cmux.dev` |
| Dev Hyperdrive | `cnx-ios-dev`, then `cmux-next-ios-dev` | `cmux-mobile-dev` (same id) |
| Prod Hyperdrive | `cnx-ios-prod`, then `cmux-next-ios` | `cmux-mobile-prod` (same id) |
| Dev database | `cmux/cnx-ios`, then `cmux/cmux-next-ios-dev` | `cmux/cmux-mobile-dev` |
| Prod database | `cmux/cnx-ios-prod`, then `cmux/cmux-next-ios` | `cmux/cmux-mobile-prod` |
| Database role | `cnx-ios-dev` / `cnx-ios-prod`, then `cmux-next-ios-dev` / `cmux-next-ios` | `cmux-mobile-api` in each database |
| Local wrangler name | `cnx-ios-api-local` | `cmux-mobile-api-local` (never deployed) |
| npm package | `cnx-ios-api` | `cmux-mobile-api` |
| APNs topics | `dev.cmux.cnx`, `dev.cmux.cnx.cnx`, `dev.cmux.cnx.prod` | `dev.cmux.mobile`, `dev.cmux.mobile.demo`, `dev.cmux.mobile.prod`; TestFlight stays `dev.cmux.app.internal` |
| Rate limit namespaces | 4101-4105 (dev), 4201-4205 (prod) | unchanged (numeric ids, no names) |

Rate limit namespaces are numbers, the TURN key and the APNs key are shared team
credentials (1Password "Cloudflare TURN Server API Key" and "cmux-next iOS APNs Auth
Key (dev.cmux.app.internal)"); none of them carried the dev tag.

`STACK_PROJECTS` in `wrangler.jsonc` lists the Stack projects whose users an
environment accepts, primary first (id, label, publishable key or `""`, invite
callback). The dev Worker accepts the dev project (primary) and the production
project for testing; production app builds use the prod Worker. A user
is (project, sub): see PROTOCOL.md "Identity and auth".

Cloudflare account `0c1675e0def6de1ab3a50a4e17dc5656`. Run wrangler as
`bunx wrangler@4` (OAuth login).

## Secrets

Set per environment with `bunx wrangler@4 secret put <NAME> --env <env>`.
Pipe values from 1Password; never paste or echo them.

| Name | Source | Required |
| --- | --- | --- |
| `TURN_KEY_ID` | 1Password `Cloudflare TURN Server API Key` (vault Shared), the "Turn Token ID" in its notes | for TURN (else `/v1/ice` is STUN only) |
| `TURN_KEY_API_TOKEN` | same item, field `credential` | for TURN |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | the team's APNs auth key (`.p8`, PKCS#8 PEM), its key id and team `7WLXT3NR37`. Not set yet: no APNs key was found in 1Password (searched 2026-10-13). Until set, `notify` answers `configured:false` | for push |
| `STACK_SECRET_SERVER_KEY` | Stack server key of the env's primary project | optional; without it membership and invites use the caller's own token (always the case for the other projects) |

```bash
op item get lqvg75d4awzbveq7ny5gyfeyd4 --fields notesPlain | grep -oE '[0-9a-f]{32}' | head -1 | tr -d '\n' \
  | bunx wrangler@4 secret put TURN_KEY_ID --env dev
op read "op://Shared/lqvg75d4awzbveq7ny5gyfeyd4/credential" | tr -d '\n' \
  | bunx wrangler@4 secret put TURN_KEY_API_TOKEN --env dev
```

`--env prod` takes the same two TURN secrets (set 2026-10-13). Check `op whoami` first: a failed `op` call pipes an empty value and wrangler
stores it.

The database URL is only in the Hyperdrive config. To create one:

```bash
pscale role create cmux-mobile-<env> main cmux-mobile-api --org cmux --inherited-roles postgres --format json > /private/path/role.json
bunx wrangler@4 hyperdrive create cmux-mobile-<env> --connection-string="$(jq -r '.database_url | split("?")[0]' /private/path/role.json)"
```

## Migrations

```bash
bun install
bunx drizzle-kit generate --name <change>       # after editing src/schema.ts
DATABASE_URL="$(jq -r .database_url /private/path/role.json)" bunx drizzle-kit migrate
```

Run migrations as the Worker's own role (`cmux-mobile-api`): it owns the tables and the
`drizzle` schema, and a role with only `--inherited-roles postgres` is refused. drizzle
applies only migrations whose journal `when` is later than the last one applied, so two
branches that each add a migration must not both land with the same index: the second to
land renumbers its migration (file, journal `idx`, snapshot `prevId`) and takes a later `when`.

Apply a migration to a database before deploying the Worker that reads it.
API 0.13.0 needs `drizzle/0004_push_settings.sql` (the `muted_macs` and
`previews` columns of `push_tokens`): a 0.13.0 Worker on a database without
them fails every `PUT /v1/devices/:id/push` and every notify. The migration
only adds columns, so the 0.12.0 Worker keeps working on a migrated database.

## Test and deploy

```bash
bun install
bunx tsc -p .
bunx vitest run                 # workerd via @cloudflare/vitest-pool-workers
bunx wrangler@4 deploy --env dev
```

## Live smoke test

`scripts/smoke.ts` exercises health, auth rejection, ICE, device upsert, team
Macs, prefs, and a two-client WebSocket exchange (hello, offer/answer, a retired
relay frame refused, refusal, offline presence) against the deployed Worker. It prints
PASS/FAIL lines only, never tokens.

```bash
# The dev test account is 1Password item sirnczouv25kkvpzlbhnpxpqo4.
STACK_EMAIL="$(op item get sirnczouv25kkvpzlbhnpxpqo4 --fields username)" \
STACK_PASSWORD="$(op read 'op://Development/sirnczouv25kkvpzlbhnpxpqo4/password')" \
  bun scripts/smoke.ts
# or with a token already saved to a 0600 file:
CMUX_MOBILE_TOKEN_FILE=/private/path/token bun scripts/smoke.ts
```

`CMUX_MOBILE_BASE_URL` selects another deployment; `STACK_PROJECT_ID` and
`STACK_PUBLISHABLE_CLIENT_KEY` (empty for production) select the Stack project
of the test account; `CMUX_MOBILE_TEAM=personal` runs against
the caller's personal space (`personal-<userId>`) instead of their first Stack team.
