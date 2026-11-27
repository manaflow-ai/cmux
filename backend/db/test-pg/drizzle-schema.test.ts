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
// drizzle-kit pull assigns index operator classes (`.op("text_ops")`) nondeterministically across
// runs (seen in CI: int8_ops on a text column), so they are not compared; the columns, order,
// uniqueness and methods still are. It also lists tables in catalog order, which an ALTER TABLE
// changes (0008_build_space moved automations and automation_runs), names its imports in first-use
// order, and writes an empty string default as `.default(')`: tables and imports are compared
// sorted, and that default as `.default('')`.
const sortedImport = (line: string) =>
  line.replace(/\{([^}]*)\}/, (_, names: string) => `{ ${names.split(",").map((name) => name.trim()).filter(Boolean).sort().join(", ")} }`)
const body = (text: string) => {
  const flat = text
    .slice(text.indexOf("import {"))
    .replace(/\r/g, "")
    .replace(/\.op\("[a-z0-9_]+"\)/g, "")
    .replace(/\.default\('\)/g, ".default('')")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
  const [head = "", ...tables] = flat.split(/\n+(?=export const )/)
  const [imports = "", ...rest] = head.split("\n")
  return [[sortedImport(imports), ...rest].join("\n").trim(), ...tables.map((table) => table.trim()).sort()].join("\n\n")
}

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
