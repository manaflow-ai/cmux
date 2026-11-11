import { DatabaseSync } from "node:sqlite"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { OwnerEngine, type Domain, type SqlStore } from "@cmux/ownership"
import * as outboxModule from "../src/owner-outbox.ts"

// The Chief brain warm (owner-outbox.ts, MuxDO wakes only) reaches the Workers runtime; no CloudDO send uses it.
vi.mock("../src/mux-wake-delivery.ts", () => ({ warmBrain: async () => {} }))

/**
 * A seeded property test of a Cloud approval answer's delivery (review of #40370), with the REAL OwnerEngine outbox
 * (node:sqlite) and the REAL drainOutboxChannels, on a fake clock. FeedDO's two senders interleave as owner-do.ts
 * runs them: the commit-time drain of the CloudDO channel (drainWakes, one at a time, `wakeAgain`) and the alarm
 * (AlarmSerial, fired at random times, so it also repeats deliveries). CloudDO is modelled as cmux-platform's
 * approvals/CloudApprovals.ts deliverCloudAnswers runs it: takeAnswer acknowledges an answer for a run in flight
 * ("already running"); execute ends done, denied, or back to pending and throws (the outbox must redeliver).
 *
 * Properties, after every history quiesces:
 * - no approved create is stranded: each request ends done or denied, or is pending with its answer still queued;
 * - nothing reaches CloudDO after its request ended (done or denied).
 */

const sqliteStore = (db: DatabaseSync): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => db.prepare(q).all(...(params as Array<never>)) as Array<T>,
  transaction: <T>(fn: () => T): T => {
    db.exec("BEGIN")
    try {
      const r = fn()
      db.exec("COMMIT")
      return r
    } catch (e) {
      db.exec("ROLLBACK")
      throw e
    }
  },
})

const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

/** feed.answer's effect on the outbox: one `integration.approval.answered` item for the team's CloudDO. */
const answers: Domain<Record<string, never>> = {
  initial: () => ({}),
  reduce: (state, _op, params) => ({
    ok: true,
    state,
    value: null,
    outbox: [{ kind: "integration.approval.answered", entity: `approval:${(params as { request: string }).request}`, payload: { request: (params as { request: string }).request, decision: "allow" }, target: { class: "CloudDO", name: "team_p" } }],
  }),
}

type State = "pending" | "running" | "done" | "denied"

const history = async (seed: number, shared: boolean) => {
  const r = rng(seed)
  const db = new DatabaseSync(":memory:")
  const engine = new OwnerEngine(sqliteStore(db), answers, { stream: "feed:user_p", now: () => Date.now() })
  const rows = new Map<string, { state: State; inFlight: number }>()
  const violations: string[] = []
  // CloudDO: the platform's takeAnswer and execute, with random run times and outcomes.
  const cloud = {
    systemDeliver: async (_entity: string, _source: string, items: ReadonlyArray<{ id: number; params: unknown }>) => {
      const done: number[] = []
      for (const item of items) {
        const request = (item.params as { request: string }).request
        const row = rows.get(request)!
        if (row.state === "done" || row.state === "denied") violations.push(`${request} delivered after it ended ${row.state}`)
        if (row.state === "running" && row.inFlight === 0) row.state = "pending" // a cut-off run: settle runs it again
        if (row.state !== "pending") {
          done.push(item.id) // takeAnswer: ignored ("request is running"), acknowledged
          continue
        }
        row.state = "running"
        row.inFlight++
        try {
          await new Promise((res) => setTimeout(res, Math.floor(r() * 3_000)))
          const roll = r()
          if (roll < 0.35) {
            row.state = "pending" // backToPending, then the throw asks the outbox to redeliver
            throw Object.assign(new Error("approved cloud.machine.create failed retryably"), { retryable: true })
          }
          row.state = roll < 0.45 ? "denied" : "done"
        } finally {
          row.inFlight--
        }
        done.push(item.id)
      }
      return { done }
    },
  }
  const ns = { idFromName: (n: string) => n, get: () => cloud } as unknown as DurableObjectNamespace
  const env = {} as never
  const prompt = (c: string) => c.startsWith("CloudDO:")
  // Read off the module, so this file also runs (red) against a build with no send lock at all.
  const { drainOutboxChannels } = outboxModule
  const Locks = (outboxModule as { ChannelLocks?: new () => outboxModule.ChannelLocks }).ChannelLocks
  const lock = () => (Locks ? new Locks() : undefined)
  const one = lock()
  const locksOf = shared ? () => one : lock
  // owner-do.ts drainWakes: one commit-time drain at a time; a commit during it looks again when it ends.
  let wake: Promise<void> | undefined
  let again = false
  const drainWakes = () => {
    if (wake) return void (again = true)
    wake = drainOutboxChannels(engine, env, () => ns, undefined, undefined, prompt, 32, locksOf())
      .catch(() => undefined)
      .finally(() => {
        wake = undefined
        if (again) [(again = false), drainWakes()]
      })
  }
  // owner-do.ts alarm: serial runs of the whole drain.
  let alarm = Promise.resolve()
  const fireAlarm = () => (alarm = alarm.then(() => drainOutboxChannels(engine, env, () => ns, undefined, undefined, undefined, Infinity, locksOf()).catch(() => undefined)))
  const requests = 1 + Math.floor(r() * 4)
  for (let i = 0; i < requests; i++) {
    const request = `apr_${seed}_${i}`
    rows.set(request, { state: "pending", inFlight: 0 })
    setTimeout(() => {
      engine.submit({ identity: "session:user_p", kind: "session", user: "user_p" }, { t: "op", op: "feed.answer", params: { request }, idempotency_key: `approve:${request}`, origin: "user" }, () => {})
      drainWakes()
      // afterCommit sets the alarm to now: it fires a little later, and the runtime may fire it more than once.
      for (let k = 0; k < 1 + Math.floor(r() * 3); k++) setTimeout(fireAlarm, Math.floor(r() * 1_500))
    }, Math.floor(r() * 2_000))
  }
  // The alarm also comes back for backed-off channels: every 2 s for the next minute.
  for (let t = 2_000; t <= 60_000; t += 2_000) setTimeout(fireAlarm, t)
  await vi.advanceTimersByTimeAsync(120_000)
  await alarm
  for (const [request, row] of rows) {
    const queued = engine.outboxPending(1_000).some((o) => o.entity === `approval:${request}`)
    if (row.state === "pending" && !queued) violations.push(`${request} stranded pending with no answer queued`)
    if (row.state === "running") violations.push(`${request} still running after the history quiesced`)
  }
  return violations
}

describe("a Cloud answer's delivery under interleaved prompt sends, alarms, duplicates and run failures", { timeout: 120_000 }, () => {
  beforeEach(() => void vi.useFakeTimers({ now: 1_700_000_000_000 }))
  afterEach(() => void vi.useRealTimers())

  it("never strands an approved create and never delivers after a terminal state (shared per-channel send lock)", async () => {
    const found: string[] = []
    for (let seed = 1; seed <= 300; seed++) found.push(...(await history(seed, true)).map((v) => `seed ${seed}: ${v}`))
    expect(found.slice(0, 5)).toEqual([])
  })

  it("the same histories without the shared lock do strand creates (the property catches the bug)", async () => {
    let stranded = 0
    for (let seed = 1; seed <= 300; seed++) stranded += (await history(seed, false)).filter((v) => v.includes("stranded")).length
    expect(stranded).toBeGreaterThan(0)
  })
})
