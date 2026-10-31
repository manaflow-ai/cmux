import type { BunPlugin } from "bun"
import { join } from "node:path"

/** Resolves `cloudflare:workers` to the self-hosted shim (bun test preload and bun build). */
export const cloudflareShim: BunPlugin = {
  name: "cloudflare-workers-shim",
  setup(build) {
    build.onResolve({ filter: /^cloudflare:workers$/ }, () => ({ path: join(import.meta.dir, "cloudflare-workers.ts") }))
  }
}
