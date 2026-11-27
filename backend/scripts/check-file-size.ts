/**
 * No god files: every hand-written source file in backend/ and clients/ts/ stays within MAX_LINES
 * lines AND MAX_BYTES bytes (a file over either limit fails). Bytes bound an agent's read cost
 * (64 KiB is about 16k tokens, one comfortable read); lines alone can be gamed by long lines.
 *
 * The limit is a backstop. Split a module by owner, domain or provider when it holds two of them,
 * not when it nears the limit; never squeeze lines to pass.
 *
 * Exempt: generated files (`generated`, `.gen.` in the name) and pure data tables (names ending in
 * `-data.ts`); every data-table exemption is printed, so a reviewer sees what it covers.
 *
 *   bun backend/scripts/check-file-size.ts
 */
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const MAX_LINES = 1000
const MAX_BYTES = 64 * 1024
const repo = fileURLToPath(new URL("../../", import.meta.url))
const roots = ["backend", "clients/ts"]
const SOURCE = /\.(ts|tsx|mts|mjs|sql)$/
const SKIP_DIRS = new Set(["node_modules", "dist", ".output", ".vercel", ".nitro", ".tanstack", ".wrangler"])
const GENERATED = /(generated|\.gen\.)/
const DATA = /-data\.ts$/

const kb = (bytes: number) => `${(bytes / 1024).toFixed(1)} KB`
const offenders: Array<string> = []
const dataExempt: Array<string> = []
const walk = (dir: string) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) {
      if (!SKIP_DIRS.has(name)) walk(path)
    } else if (SOURCE.test(name) && !GENERATED.test(name)) {
      const text = readFileSync(path, "utf8")
      const lines = text.split("\n").length
      const bytes = Buffer.byteLength(text)
      if (lines <= MAX_LINES && bytes <= MAX_BYTES) continue
      const line = `${relative(repo, path)}: ${lines} lines, ${kb(bytes)} (max ${MAX_LINES} lines, ${kb(MAX_BYTES)})`
      if (DATA.test(name)) dataExempt.push(line)
      else offenders.push(line)
    }
  }
}
for (const r of roots) walk(join(repo, r))
for (const d of dataExempt) console.log(`file size: data table exempt: ${d}`)
if (offenders.length) {
  for (const o of offenders) console.error(`file size: ${o}`)
  process.exit(1)
}
console.log(`file size ok: every source file in ${roots.join(", ")} has at most ${MAX_LINES} lines and ${kb(MAX_BYTES)}`)
