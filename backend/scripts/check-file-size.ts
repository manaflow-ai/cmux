/**
 * No god files: every hand-written source file in backend/ and clients/ts/ stays at or
 * under MAX_LINES. Generated files (`generated`, `.gen.` in the name) are exempt; split a
 * growing module by owner, domain or provider instead of raising the limit.
 *
 *   bun backend/scripts/check-file-size.ts
 */
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const MAX_LINES = 500
const repo = fileURLToPath(new URL("../../", import.meta.url))
const roots = ["backend", "clients/ts"]
const SOURCE = /\.(ts|tsx|mts|mjs|sql)$/
const SKIP_DIRS = new Set(["node_modules", "dist", ".output", ".vercel", ".nitro", ".tanstack", ".wrangler"])
const GENERATED = /(generated|\.gen\.)/

const offenders: Array<string> = []
const walk = (dir: string) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) {
      if (!SKIP_DIRS.has(name)) walk(path)
    } else if (SOURCE.test(name) && !GENERATED.test(name)) {
      const lines = readFileSync(path, "utf8").split("\n").length
      if (lines > MAX_LINES) offenders.push(`${relative(repo, path)}: ${lines} lines (max ${MAX_LINES})`)
    }
  }
}
for (const r of roots) walk(join(repo, r))
if (offenders.length) {
  for (const o of offenders) console.error(`file size: ${o}`)
  process.exit(1)
}
console.log(`file size ok: every source file in ${roots.join(", ")} has at most ${MAX_LINES} lines`)
