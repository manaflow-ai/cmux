import type { Api, AssistantMessage, Model } from "@earendil-works/pi-ai"
import { describe, expect, it } from "vitest"
import { Compactor, type CompactorHold, type PumpHost } from "../src/chief-brain/compactor.ts"
import { JOBS } from "../src/chief-brain/memory.ts"

/**
 * The staging credit drain of 2026-10-28: the staging Bedrock credential was bad, so every compactor
 * call failed at once with "403 The security token included in the request is invalid." (no tokens,
 * a $0 charge). Each of a Chief's up to 64 unbuilt nodes backed off on its own, and the backoff lived
 * only in memory, so every object restart began again at 2 s. About 55 chiefs made about 2,600 calls
 * per minute (up to 365 a minute for one chief, over 70,000 each in the ledger).
 *
 * The compactor now holds every node after a failure (one shared, growing wait), waits much longer
 * on a failure the next try hits again (bad credential: 401/403), and keeps that hold in the
 * object's storage, so a restart does not start the loop again.
 */
const MODEL = { provider: "claude-david", id: "claude-haiku-5-5", maxTokens: 1024 } as unknown as Model<Api>
const failedReply = (errorMessage: string) =>
  ({ role: "assistant", content: [], stopReason: "error", errorMessage, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, timestamp: Date.now() }) as unknown as AssistantMessage

/** A log with `n` unbuilt level-0 nodes; pump hands out up to JOBS of them, as the core does. */
const fakeMemory = (n: number) => {
  const busy = new Set<number>()
  const built = new Set<number>()
  return {
    generation: 0,
    pump: () => {
      const out: Array<{ kind: "model"; l: number; i: number }> = []
      for (let i = 0; i < n && busy.size < JOBS; i++) if (!busy.has(i) && !built.has(i)) [busy.add(i), out.push({ kind: "model", l: 0, i })]
      return out
    },
    fail: (_l: number, i: number) => void busy.delete(i),
    complete: (_l: number, i: number) => void [busy.delete(i), built.add(i)],
    settled: () => built.size === n,
    first: () => 0,
    compactRequest: () => ({ system: "sys", context: "", marks: [], step: "step", cut: null, room: 10_000 })
  }
}

const host = (error: string, opts: { hold?: CompactorHold; wakes?: Array<number> } = {}) => {
  const calls: Array<number> = []
  const memory = fakeMemory(64)
  const models = { completeSimple: async () => (calls.push(Date.now()), failedReply(error)) }
  const h: PumpHost = {
    memory: memory as unknown as PumpHost["memory"],
    deps: () => ({ memory: memory as never, models: models as never, model: MODEL, prompt: "cmux", agent: "agent_test", record: () => undefined }),
    onBuilt: () => undefined,
    onFirstFailure: () => undefined,
    onRetryWait: (at) => void opts.wakes?.push(at),
    retryBaseMs: 50,
    random: () => 0.999,
    ...(opts.hold ? { hold: opts.hold } : {})
  }
  return { h, calls }
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const memoryHold = (): CompactorHold & { value: { until: number; streak: number } | undefined } => {
  const box = {
    value: undefined as { until: number; streak: number } | undefined,
    read: () => box.value,
    write: (v: { until: number; streak: number }) => void (box.value = v)
  }
  return box
}

describe("compactor backoff is shared by every node and survives a restart", { timeout: 20_000 }, () => {
  it("a bad credential (403) on every node stops after one batch, not one retry chain per node", async () => {
    const { h, calls } = host("403 The security token included in the request is invalid.")
    new Compactor(h).pump()
    await sleep(1_500)
    // Before: 64 nodes each retried at 50, 100, 200, 400, 800 ms: about 300 calls in 1.5 s.
    expect(calls.length).toBeLessThanOrEqual(JOBS)
  })

  it("a transient failure on every node spaces whole batches, so the calls stay below one per node", async () => {
    const { h, calls } = host("500 internal server error")
    new Compactor(h).pump()
    await sleep(1_500)
    expect(calls.length).toBeLessThan(64)
  })

  it("a restarted object keeps the hold: no call before it ends, and a wake is set for its end", async () => {
    const hold = memoryHold()
    const first = host("403 The security token included in the request is invalid.", { hold })
    new Compactor(first.h).pump()
    await sleep(300)
    expect(first.calls.length).toBeGreaterThan(0)
    expect(hold.value?.until ?? 0).toBeGreaterThan(Date.now() + 20_000)

    const wakes: Array<number> = []
    const again = host("403 The security token included in the request is invalid.", { hold, wakes })
    new Compactor(again.h).pump()
    await sleep(500)
    expect(again.calls.length).toBe(0)
    expect(Math.max(0, ...wakes)).toBeGreaterThanOrEqual(hold.value!.until)
  })
})
