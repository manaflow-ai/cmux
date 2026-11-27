import { plugin } from "bun"
import * as shim from "./cloudflare-workers.ts"

// Runtime (bun run, bun test): `cloudflare:workers` is a virtual module backed by the shim.
plugin({
  name: "cloudflare-workers-shim",
  setup(build) {
    build.module("cloudflare:workers", () => ({ exports: { ...shim }, loader: "object" }))
  }
})
