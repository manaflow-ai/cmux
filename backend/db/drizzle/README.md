# Drizzle snapshots (not migrations)

`drizzle-kit generate` diffs `schema/` against the newest snapshot in `meta/` and writes the
delta SQL here. `0000_baseline.sql` is the baseline of the 0001-0006 migrations and is never
applied. For a schema change: edit `schema/index.ts`, run `bun run db:generate`, review the new
SQL, copy it into `../migrations/NNNN_<name>.sql` with the expand header (it must pass
`bun migrate.ts --lint`), and commit both the snapshot and the migration. The migration is applied
only through the backend:apply-migrations gate; `test-pg/drizzle-schema.test.ts` then proves the
schema equals the migrated database.
