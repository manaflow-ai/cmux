import { join } from "node:path"
import { cloudflareShim } from "../src/shims/plugin.ts"

/**
 * One executable per target: `bun build --compile` with `cloudflare:workers` resolved to the shim.
 * Usage: bun scripts/build.ts [--target bun-darwin-arm64|bun-darwin-x64|bun-linux-x64|bun-linux-arm64]... [--out DIR]
 */
const args = process.argv.slice(2)
const targets = args.flatMap((a, i) => (a === "--target" ? [args[i + 1]!] : []))
const out = args.includes("--out") ? args[args.indexOf("--out") + 1]! : join(import.meta.dir, "..", "dist")
for (const target of targets.length ? targets : [undefined]) {
  const name = target ? `cmux-chat-server-${target.replace(/^bun-/, "")}` : "cmux-chat-server"
  const r = await Bun.build({
    entrypoints: [join(import.meta.dir, "..", "src", "main.ts")],
    plugins: [cloudflareShim],
    compile: { outfile: join(out, name), ...(target ? { target: target as never } : {}) },
    minify: true,
    sourcemap: "none"
  })
  if (!r.success) {
    for (const l of r.logs) console.error(String(l))
    process.exit(1)
  }
  console.log(join(out, name))
}
