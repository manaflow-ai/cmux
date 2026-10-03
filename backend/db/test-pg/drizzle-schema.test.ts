import { describe, expect, it } from "bun:test"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

/**
 * The Drizzle schema equals the database the committed migrations build (C-BATCH 2): pull the
 * migrated scratch Postgres again with drizzle-kit and compare it with schema/index.ts. A schema
 * change lands as: edit schema/, `drizzle-kit generate`, review the SQL, commit it as the next
 * migrations/NNNN_*.sql (expand lint), and this test stays green after CI applies it.
 */
const url = process.env.SCRATCH_URL
const run = url ? describe : describe.skip
const root = join(import.meta.dir, "..")
const body = (text: string) => text.slice(text.indexOf("import {")).replace(/\r/g, "").replace(/\n{3,}/g, "\n\n").trim()

run("Drizzle schema", () => {
  it("matches the migrated database (drizzle-kit pull)", () => {
    const dir = mkdtempSync(join(tmpdir(), "drizzle-pull-"))
    try {
      // The config sits next to node_modules so it can import drizzle-kit; the output goes to the temp dir.
      const config = join(root, `.drizzle-pull-${process.pid}.config.ts`)
      writeFileSync(
        config,
        `import { defineConfig } from "drizzle-kit"\nexport default defineConfig({ dialect: "postgresql", out: ${JSON.stringify(join(dir, "out"))}, dbCredentials: { url: process.env.SCRATCH_URL ?? "" }, tablesFilter: ["!schema_migrations", "!home_message_search_p*"] })\n`
      )
      const pull = Bun.spawnSync([join(root, "node_modules", ".bin", "drizzle-kit"), "pull", "--config", config], { cwd: root, env: { ...process.env } })
      expect(pull.exitCode).toBe(0)
      const pulled = readFileSync(join(dir, "out", "schema.ts"), "utf8")
      expect(body(pulled)).toBe(body(readFileSync(join(root, "schema", "index.ts"), "utf8")))
    } finally {
      rmSync(dir, { recursive: true, force: true })
      rmSync(join(root, `.drizzle-pull-${process.pid}.config.ts`), { force: true })
    }
  }, 120_000)
})
