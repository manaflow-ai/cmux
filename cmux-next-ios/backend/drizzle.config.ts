import { defineConfig } from "drizzle-kit"

// DATABASE_URL comes from the environment only (a PlanetScale role URL); never commit it.
export default defineConfig({
  dialect: "postgresql",
  schema: "./src/schema.ts",
  out: "./drizzle",
  dbCredentials: { url: process.env.DATABASE_URL ?? "" }
})
