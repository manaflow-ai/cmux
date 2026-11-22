import { exports } from "cloudflare:workers"
import { beforeAll } from "vitest"

/**
 * The first request a test file sends evaluates the whole Worker module (src/index.ts, every
 * Durable Object class) in that file's fresh isolate: about 0.3 s alone, several seconds when
 * ~40 files load at once on a busy host. Measured 2026-10-03: in server-pairing "begins with
 * proof" the first request took 475 ms of a 600 ms test; with this warm-up it takes 24 ms. The
 * cost is per file, not per test, so it is paid here, under a hook timeout, and never inside a
 * test's 5 s timeout. No test depends on the module being cold.
 */
const worker = (exports as unknown as { default: Fetcher }).default

beforeAll(async () => {
  await (await worker.fetch("https://api.test/v1/health")).arrayBuffer()
}, 120_000)
