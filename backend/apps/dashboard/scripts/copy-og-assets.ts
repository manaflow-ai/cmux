/**
 * Copies the invite-card renderer's runtime assets into public/og/runtime/ under fixed names,
 * so they ship as static files in dev and on Vercel (server-side `?url` imports are not emitted
 * to the static output). The copies are gitignored; package versions pin their content.
 */
import { copyFileSync, mkdirSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const require = createRequire(import.meta.url)
const out = join(here, "..", "public", "og", "runtime")
mkdirSync(out, { recursive: true })
const copies: Array<[string, string]> = [
  ["@resvg/resvg-wasm/index_bg.wasm", "resvg.wasm"],
  ["@fontsource/inter/files/inter-latin-700-normal.woff", "inter-700.woff"],
  ["@fontsource/inter/files/inter-latin-500-normal.woff", "inter-500.woff"]
]
for (const [from, to] of copies) copyFileSync(require.resolve(from), join(out, to))
console.log(`og runtime assets: ${copies.map(([, to]) => to).join(", ")}`)
