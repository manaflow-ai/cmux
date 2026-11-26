import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test"
import { expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { token } from "../test/helpers.ts"

// scripts/ice-netcond.sh copies this as ice-before.test.ts or ice-after.test.ts.
// Only Date.now is offset for cache age. Timers and the latency clock stay real.
const phase = import.meta.url.includes("ice-before.test.ts") ? "before" : "after"
const profiles = ["true-cold", "cold-isolate", "warm-isolate", "past-soft-ttl"] as const
const runs = 50
const freshHandler = async () => {
  vi.resetModules()
  return (await import("../src/index.ts")).default
}

async function request(handler: Awaited<ReturnType<typeof freshHandler>>, bindings: Env, jwt: string) {
  const req = new Request("https://api.test/v1/ice", { headers: { authorization: `Bearer ${jwt}` } })
  const ctx = createExecutionContext()
  const start = performance.now()
  const response = await handler.fetch(req, bindings, ctx)
  const body = await response.json<{ turn: boolean; iceServers: Array<{ username?: string }> }>()
  const ms = performance.now() - start
  await waitOnExecutionContext(ctx)
  expect(response.status).toBe(200)
  expect(body.turn).toBe(true)
  return { username: body.iceServers.find((server) => server.username)?.username, ms }
}

for (const profile of profiles) {
  it(`GET /v1/ice ${phase} ${profile}`, async () => {
    const samples: number[] = []
    const wallNow = Date.now.bind(Date)
    let ageMs = 0
    let priming = false
    let mints = 0
    vi.spyOn(Date, "now").mockImplementation(() => wallNow() + ageMs)
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const req = new Request(input, init)
      expect(new URL(req.url).host).toBe("rtc.live.cloudflare.com")
      expect(req.method).toBe("POST")
      const username = `test-mint-${++mints}`
      if (!priming) {
        await new Promise<void>((resolve, reject) => {
          const abort = () => {
            clearTimeout(timer)
            reject(req.signal.reason)
          }
          const timer = setTimeout(() => {
            req.signal.removeEventListener("abort", abort)
            resolve()
          }, 2000)
          if (req.signal.aborted) abort()
          else req.signal.addEventListener("abort", abort, { once: true })
        })
      }
      return Response.json({ iceServers: [{ urls: ["turn:relay.test:3478"], username, credential: "test-only" }] })
    })
    try {
      for (let run = 1; run <= runs; run++) {
        ageMs = 0
        mints = 0
        const bindings = { ...env, TURN_KEY_ID: `bench-${phase}-${profile}-${run}`, TURN_KEY_API_TOKEN: "test-only", ICE_TTL_SECONDS: "300" } as unknown as Env
        const jwt = await token("ice-bench")
        const first = await freshHandler()
        // Resetting modules invalidates active Miniflare Durable Object stubs.
        // Load both independent Worker modules before either opens shared storage.
        const handler = profile === "cold-isolate" ? await freshHandler() : first
        if (profile === "cold-isolate") expect(handler).not.toBe(first)
        if (profile !== "true-cold") {
          priming = true
          expect((await request(first, bindings, jwt)).username).toBe("test-mint-1")
          priming = false
        }
        if (profile === "past-soft-ttl") ageMs = 151_000
        const result = await request(handler, bindings, jwt)
        const baseMiss = phase === "before" && (profile === "cold-isolate" || profile === "past-soft-ttl")
        expect(result.username).toBe(baseMiss ? "test-mint-2" : "test-mint-1")
        // A stale hit still refreshes after handing back the first mint.
        expect(mints).toBe(baseMiss || profile === "past-soft-ttl" ? 2 : 1)
        samples.push(result.ms)
        console.log(`NETCOND ${JSON.stringify({ surface: "worker-ice", profile, phase, metric: "ice_ms", value: result.ms, run, seed: 0 })}`)
      }
      samples.sort((a, b) => a - b)
      console.log(`ICE_PERCENTILES ${JSON.stringify({ profile, phase, n: runs, p50: samples[Math.ceil(runs * 0.5) - 1], p95: samples[Math.ceil(runs * 0.95) - 1] })}`)
    } finally {
      vi.restoreAllMocks()
    }
  }, 300_000)
}
