# Every Table Has a Bound or a Drain

Apply this rule to changes under `web/db/schema.ts`, `web/db/migrations/`, and any `web/` code that inserts rows. The registry `web/db/retention.ts` is the source of truth: every table declares `bounded` (one row per named entity, deleted with it), `permanent`, or `drain` (a cutoff column the generic cron deletes past, or a table-specific cron route). `web/tests/db-retention-registry.test.ts` fails when a table is missing, so this rule catches what the test cannot: entries that are technically valid but wrong.

The lessons are from the Aurora ledger before the PlanetScale move: `iroh_registration_challenges` grew to 4.7 GB in 35 hours with eight indexes, `cloud_vm_usage_events` reached 35,000 rows of which 96% were per-command telemetry nobody read back, and `cloud_vm_leases` held 11,000 rows that were all expired because the cron only marked them.

## Fail

- A new table whose registry entry says `bounded` but whose rows are created per request, per command, per heartbeat, per session, or per attempt (event, log, issuance, lease, challenge, delivery, attempt, audit). Those are drains.
- A new insert path that writes one row per request or per command into Postgres when the row is only read by analytics. Per-command telemetry goes to PostHog, Axiom, or ClickHouse.
- A row with an `expires_at`, `revoked_at`, `consumed_at`, or `closed_at` column whose only lifecycle is being marked, with no drain that deletes it after a stated window.
- A drain entry whose cutoff column is not the column the code expires on, or a `route` entry pointing at a cron that does not delete from that table.
- A PR that adds a table or insert path without stating the expected rows per day and the retention window in its description.

## Pass

- A `bounded` table keyed by user, device, team, VM, or another entity that the account deletion path removes.
- A `drain` entry with a timestamp cutoff column and a window justified in the PR (idempotency windows, support lookback, billing audit).
- A `permanent` entry with a stated reason (deletion tombstones).
- A high-volume event forwarded to PostHog through an existing capture path with no Postgres row.

## Report

When this rule fails, name the table and the insert site, say which lifecycle produces unbounded rows, and propose the registry entry (`drain` column and days, or the non-Postgres sink) the change should ship with.
