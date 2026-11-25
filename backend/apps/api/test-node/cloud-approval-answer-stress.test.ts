import { describe, expect, it } from "vitest"

/**
 * Compressed synthetic stress for a Cloud create's approval round (a claimed spare's "machine_created" mark): many
 * concurrent starts on a fake clock, with injected latency on each dependency and dropped or slow responses, run twice
 * from the same seeds: the person's answer delivered by FeedDO's alarm (before) and at commit with feed.answer's
 * bounded wait (after, feed-do.ts promptChannel and approvalAnswerChannel).
 *
 * A model of the protocol, not the Workers runtime; each step names the code it stands for:
 * - the Mac (CmuxNextApp/Cloud/CloudService+AppServer.swift appServerCreate, CloudMachineCreateFlow.swift
 *   approvalLoop and backoff 1, 2, 4, 8 s; CmuxNextDaemonService/CloudApprovalAnswer.swift: approval.get, feed.list,
 *   feed.answer; 15 s request timeout);
 * - CloudDO's gate (cmux-platform src/server/cloud/approvals/CloudApprovals.ts gateCloudRequest: pending answers at once,
 *   a running run in flight is waited for up to APPROVED_RUN_WAIT_MS 10 s; deliverCloudAnswers: answerAdmitted, then
 *   startRun and the run; one object per team, its synchronous steps one at a time);
 * - FeedDO (owner-do.ts afterCommit, drainWakes, promptDrained 2 s; the alarm drains the rest).
 * The real FeedDO's commit-time delivery is tested in test/feed-cloud-answer-delivery.test.ts.
 */

// ------------------------------------------------------------------ the fake clock

class Clock {
  now = 0
  private timers: Array<{ at: number; seq: number; fire: () => void }> = []
  private seq = 0
  sleep(ms: number): Promise<void> {
    return new Promise((fire) => this.timers.push({ at: this.now + Math.max(0, ms), seq: this.seq++, fire }))
  }
  /** Runs every timer in time order until none is left; returns the virtual time spent. */
  async run(): Promise<number> {
    for (;;) {
      await new Promise((r) => setImmediate(r))
      if (this.timers.length === 0) return this.now
      this.timers.sort((a, b) => a.at - b.at || a.seq - b.seq)
      const t = this.timers.shift()!
      this.now = t.at
      t.fire()
    }
  }
}

/** mulberry32: the same seed gives both arms the same draws in the same order. */
const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

// ------------------------------------------------------------------ the dependencies and their faults

interface Faults {
  /** Median one-way ms of each dependency (lognormal around it). */
  readonly relay: number
  readonly stack: number
  readonly platform: number
  readonly carrier: number
  /** FeedDO's alarm: how long after its set time it runs (median ms). */
  readonly alarm: number
  /** The approved run (a spare claim: entitlements, the Scaler's claim, the adopting commit), median ms. */
  readonly run: number
  /** Per Mac request: dropped (no answer until the 15 s timeout, then sent again) and slow (x8). */
  readonly drop: number
  readonly slow: number
}

const NOMINAL: Faults = { relay: 60, stack: 15, platform: 25, carrier: 300, alarm: 250, run: 1_200, drop: 0.01, slow: 0.05 }

const MAC_TIMEOUT_MS = 15_000
const APPROVED_RUN_WAIT_MS = 10_000
const PROMPT_DRAIN_WAIT_MS = 2_000
const backoff = (attempt: number) => 1_000 * Math.min(8, 1 << Math.min(Math.max(attempt - 1, 0), 3))

type Mode = "alarm" | "commit"

/** One start's view of the world: the shared fake clock and faults, and its own seeded draws, so both arms draw the
 * same latencies and faults for the same start whatever the other starts do. */
class World {
  private readonly rand: () => number
  constructor(readonly clock: Clock, readonly f: Faults, private readonly seed: number) {
    this.rand = rng(seed)
  }
  /** The draws of one named step of this start: the same in both arms, whatever the steps before it drew. */
  sub(label: string): World {
    let h = this.seed | 0
    for (const c of label) h = Math.imul(h ^ c.charCodeAt(0), 0x9e3779b1)
    return new World(this.clock, this.f, h)
  }
  /** Lognormal around `median` (sigma 0.5): Box-Muller on the seeded draws. */
  lat(median: number, sigma = 0.5): number {
    const u = Math.max(this.rand(), 1e-9)
    const v = this.rand()
    return median * Math.exp(sigma * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v))
  }
  wait(median: number, sigma?: number) {
    return this.clock.sleep(this.lat(median, sigma))
  }
  /** One Mac request through the app server's relay to the API Worker (Stack session check) and back, around `server`. */
  async request<T>(server: () => Promise<T>): Promise<T> {
    for (;;) {
      const slow = this.rand() < this.f.slow ? 8 : 1
      const dropped = this.rand() < this.f.drop
      const sent = this.clock.now
      await this.clock.sleep(this.lat(this.f.relay) * slow + this.lat(this.f.stack))
      const value = await server()
      if (dropped) {
        // The answer never comes back: the Mac waits out its timeout and sends the same request (same key) again.
        await this.clock.sleep(Math.max(0, sent + MAC_TIMEOUT_MS - this.clock.now))
        continue
      }
      await this.clock.sleep(this.lat(this.f.relay) * slow)
      return value
    }
  }
  /** One RPC hop between Workers objects. */
  hop() {
    return this.wait(this.f.platform)
  }
}

/** A team's CloudDO: one object, its synchronous steps one at a time; the approval rows by request. */
class CloudDO {
  private busy: Promise<void> = Promise.resolve()
  readonly rows = new Map<string, { state: "pending" | "running" | "done"; ended: Promise<void>; end: () => void }>()
  constructor(private readonly clock: Clock) {}
  /** A synchronous step (sql, the reducer): 4 ms, queued behind every other caller of this object. */
  step(): Promise<void> {
    const next = this.busy.then(() => this.clock.sleep(4))
    this.busy = next
    return next
  }
  post(request: string) {
    let end!: () => void
    const ended = new Promise<void>((r) => (end = r))
    this.rows.set(request, { state: "pending", ended, end })
  }
  /** gateCloudRequest on a same-key retry: done replays, running in flight waits (bounded), pending answers at once. */
  async gate(request: string): Promise<"done" | "pending"> {
    await this.step()
    const row = this.rows.get(request)!
    if (row.state === "running")
      await Promise.race([row.ended, this.clock.sleep(APPROVED_RUN_WAIT_MS)])
    await this.step()
    return row.state === "done" ? "done" : "pending"
  }
  /** deliverCloudAnswers: answerAdmitted (TeamDO read, sign-in rules), startRun, the run; resolves when it ends. */
  async deliver(w: World, request: string, run: number) {
    await w.hop()
    await this.step()
    await w.hop()
    await w.hop()
    const row = this.rows.get(request)!
    if (row.state !== "pending") return
    row.state = "running"
    await this.clock.sleep(run)
    await this.step()
    row.state = "done"
    row.end()
  }
}

/** One start from select to machine_created, then the carrier dial (ticket, relay, handshake) to connected. */
const start = async (w: World, cloud: CloudDO, mode: Mode, id: number) => {
  const t0 = w.clock.now
  const request = `apr_${id}`
  // user.ensure (UserDO), then the create: CloudDO's gate posts the approval to the person's FeedDO and answers pending.
  await w.sub("ensure").request(async () => void (await w.hop(), await w.wait(5), await w.hop()))
  await w.sub("create").request(async () => {
    await w.hop()
    await cloud.step()
    await w.hop()
    await w.hop()
    cloud.post(request)
    await w.hop()
  })
  // The Mac checks the request it answers: integration.approval.get (FeedDO, then CloudDO) and feed.list (FeedDO).
  await w.sub("get").request(async () => void (await w.hop(), await w.hop(), await w.hop(), await cloud.step(), await w.hop(), await w.hop()))
  await w.sub("list").request(async () => void (await w.hop(), await w.wait(5), await w.hop()))
  // feed.answer: FeedDO commits the answer, whose outbox item goes to CloudDO.
  const a = w.sub("answer")
  await a.request(async () => {
    await w.hop()
    await w.wait(5)
    // Drawn in both arms, so the two arms stay paired draw for draw.
    const alarm = w.lat(w.f.alarm, 1.0)
    const run = w.lat(w.f.run)
    const hops = w.sub("deliver")
    if (mode === "alarm") {
      // Before: the alarm sends it; the answer returns at once.
      void w.clock.sleep(alarm).then(() => cloud.deliver(hops, request, run))
    } else {
      // After: sent at commit; the answer returns once the delivery ended, or after PROMPT_DRAIN_WAIT_MS.
      const delivered = cloud.deliver(hops, request, run)
      await Promise.race([delivered, w.clock.sleep(PROMPT_DRAIN_WAIT_MS)])
    }
    await w.hop()
  })
  // The same-key retries: the first at once, then the backoff after each pending answer.
  for (let attempt = 1; ; attempt++) {
    const r = w.sub(`retry-${attempt}`)
    const answer = await r.request(async () => {
      await r.hop()
      const g = await cloud.gate(request)
      await r.hop()
      return g
    })
    if (answer === "done") break
    await w.clock.sleep(backoff(attempt))
  }
  const created = w.clock.now - t0
  // The carrier dial (ticket, relay, handshake): the same in both arms, injected like the rest.
  const c = w.sub("carrier")
  await c.request(async () => void (await c.hop(), await c.hop()))
  await c.wait(c.f.carrier)
  await c.wait(c.f.carrier * 2)
  return { created, connected: w.clock.now - t0 }
}

const pct = (xs: ReadonlyArray<number>, p: number) => {
  const s = [...xs].sort((a, b) => a - b)
  return Math.round(s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]!)
}

/** `starts` concurrent starts, `perTeam` of them sharing one CloudDO, repeated over `rounds` seeds. */
const stress = async (mode: Mode, f: Faults, starts = 400, perTeam = 40, rounds = 3) => {
  const created: number[] = []
  const connected: number[] = []
  for (let round = 0; round < rounds; round++) {
    const clock = new Clock()
    const teams = Array.from({ length: Math.ceil(starts / perTeam) }, () => new CloudDO(clock))
    const all = Array.from({ length: starts }, (_, i) => start(new World(clock, f, round * 100_003 + i), teams[Math.floor(i / perTeam)]!, mode, i))
    await clock.run()
    for (const r of await Promise.all(all)) [created.push(r.created), connected.push(r.connected)]
  }
  return { p50: pct(created, 50), p95: pct(created, 95), connected_p50: pct(connected, 50), connected_p95: pct(connected, 95) }
}

const SCENARIOS: ReadonlyArray<[string, Faults]> = [
  ["nominal", NOMINAL],
  ["slow relay (x3)", { ...NOMINAL, relay: 180 }],
  ["slow platform (x4)", { ...NOMINAL, platform: 100 }],
  ["slow Stack (x10)", { ...NOMINAL, stack: 150 }],
  ["slow alarm (1.5 s)", { ...NOMINAL, alarm: 1_500 }],
  ["drops 5%, slow 10%", { ...NOMINAL, drop: 0.05, slow: 0.1 }],
  ["slow claim run (4 s)", { ...NOMINAL, run: 4_000 }],
]

describe("a Cloud create's approval round under synthetic stress", { timeout: 120_000 }, () => {
  it("is faster at p50, and no slower at p95, with the answer delivered at commit, in every fault scenario", async () => {
    const rows: string[] = []
    const results: Array<[string, Awaited<ReturnType<typeof stress>>, Awaited<ReturnType<typeof stress>>]> = []
    for (const [name, f] of SCENARIOS) {
      const before = await stress("alarm", f)
      const after = await stress("commit", f)
      rows.push(
        `${name.padEnd(22)} created p50 ${before.p50} -> ${after.p50} ms, p95 ${before.p95} -> ${after.p95} ms; connected p50 ${before.connected_p50} -> ${after.connected_p50}, p95 ${before.connected_p95} -> ${after.connected_p95}`,
      )
      results.push([name, before, after])
    }
    console.log(`1,200 starts per arm per scenario (400 concurrent, 40 per team, 3 seeds):\n${rows.join("\n")}`)
    for (const [name, before, after] of results) {
      expect(after.p50, name).toBeLessThan(before.p50)
      // p95 is the drop tail (a dropped answer waits out the Mac's 15 s timeout, in both arms): no worse than its noise.
      expect(after.p95, name).toBeLessThanOrEqual(before.p95 * 1.02)
    }
  })
})
