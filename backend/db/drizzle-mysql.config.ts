import { defineConfig } from "drizzle-kit"

/** PlanetScale MySQL (Vitess) schema history. `bun run db:generate:mysql` writes the next migration. */
export default defineConfig({
  dialect: "mysql",
  schema: "./schema-mysql/index.ts",
  out: "./drizzle-mysql"
})
