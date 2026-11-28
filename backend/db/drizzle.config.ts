import { defineConfig } from "drizzle-kit"

/**
 * Drizzle owns the cmux-next schema (coordinator decision C-BATCH 2). `schema/` is the source;
 * `drizzle-kit generate` writes the SQL for review, which lands as the next NNNN_*.sql file and
 * goes through the backend:apply-migrations gate. test-pg/drizzle-schema.test.ts proves that the
 * schema equals the database the committed migrations build. schema_migrations is the runner's
 * own ledger and stays outside the schema.
 */
export default defineConfig({
  dialect: "postgresql",
  schema: "./schema/index.ts",
  out: "./drizzle",
  dbCredentials: { url: process.env.SCRATCH_URL ?? "" },
  tablesFilter: ["!schema_migrations", "!home_message_search_p*"],
  extensionsFilters: ["postgis"]
})
