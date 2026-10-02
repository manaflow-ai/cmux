import { idFactory, type Origin, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { dedupeSlot, isActive, MAX_ITEMS, MAX_OPEN_REQUESTS, type FeedState } from "../src/domains/feed-state.ts"
import { feedDomain } from "../src/domains/feed.ts"
import { agentA, agentB, approvePrompt, choicePrompt, daemon, mac, phone, run, system } from "./feed-harness.ts"

/** FeedDO's event actor projection (feed-do.ts constructor). */
const eventActor = (p: Principal): Principal => ({
  identity: p.identity,
  ...(p.kind ? { kind: p.kind } : {}),
  ...(p.user ? { user: p.user } : {}),
  ...(p.install ? { install: p.install } : {}),
  ...(p.install_kind ? { install_kind: p.install_kind } : {}),
  ...(p.agent ? { agent: p.agent } : {})
})

/** Small deterministic PRNG (mulberry32), so a failing seed reproduces. */
const rng = (seed: number) => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

interface LogEntry {
  readonly p: Principal
  readonly op: string
  readonly params: unknown
  readonly now: number
  readonly tx: string
  readonly origin: Origin
}

/** Invariants of feed.md 3.5, 3.6 and section 4, checked after every committed op. */
const check = (s: FeedState, prev: FeedState) => {
  const items = Object.values(s.items)
  // I1: the dedupe index points only at active items whose slot matches; at most one active claim per slot.
  for (const [slot, id] of Object.entries(s.dedupe)) {
    const i = s.items[id]
    if (!i || !isActive(i) || dedupeSlot(i) !== slot) throw new Error(`I1 dedupe ${JSON.stringify(slot)} -> ${id} is stale`)
  }
  // I2: lifecycle fields agree with the state.
  for (const i of items) {
    if ((i.state === "answered") !== (i.answer !== null)) throw new Error(`I2 answer of ${i.id}`)
    if ((i.state === "cancelled") !== (i.cancel !== null)) throw new Error(`I2 cancel of ${i.id}`)
    if ((i.state !== "open") !== (i.closed_at !== null)) throw new Error(`I2 closed_at of ${i.id}`)
    if (i.type === "notice" && i.state === "answered") throw new Error(`I2 answered notice ${i.id}`)
  }
  // I3: bounds.
  if (items.length > MAX_ITEMS) throw new Error("I3 too many items")
  if (items.filter((i) => i.type === "request" && i.state === "open").length > MAX_OPEN_REQUESTS) throw new Error("I3 too many open requests")
  // I4: a closed item never reopens or changes its answer; I5: revisions only grow; I6: open requests are never dropped.
  for (const before of Object.values(prev.items)) {
    const after = s.items[before.id]
    if (!after) {
      if (before.type === "request" && before.state === "open") throw new Error(`I6 open request ${before.id} dropped`)
      continue
    }
    if (before.state !== "open" && (after.state !== before.state || JSON.stringify(after.answer) !== JSON.stringify(before.answer))) throw new Error(`I4 ${before.id} changed after close`)
    if (after.revision < before.revision) throw new Error(`I5 revision of ${before.id} went back`)
    if (after.revision === before.revision && JSON.stringify(after) !== JSON.stringify(before)) throw new Error(`I5 ${before.id} changed without a revision`)
  }
  // I7: order is unique.
  if (new Set(items.map((i) => i.order)).size !== items.length) throw new Error("I7 order not unique")
}

const posters = [agentA, agentB, daemon]
const users: ReadonlyArray<[Principal, Origin]> = [[mac, "user"], [phone, "user"], [mac, "cli"], [agentA, "user"]]

const randomOp = (r: () => number, s: FeedState, now: number): { p: Principal; op: string; params: unknown; origin: Origin } => {
  const pick = <T>(xs: ReadonlyArray<T>) => xs[Math.floor(r() * xs.length)]!
  const ids = Object.keys(s.items)
  const anyId = () => (ids.length > 0 && r() < 0.9 ? pick(ids) : "fi_00000000000000000000")
  const x = r()
  if (x < 0.35) {
    const p = pick(posters)
    const key = r() < 0.5 ? { dedupe_key: `k${Math.floor(r() * 4)}` } : {}
    const expiry = r() < 0.3 ? { expires_in_ms: 10_000 + Math.floor(r() * 50_000) } : {}
    const kind = pick(["notice", "approve", "choice", "confirm"])
    const prompt = kind === "approve" ? approvePrompt : kind === "choice" ? choicePrompt : kind === "confirm" ? { statement: "Delete?" } : undefined
    return { p, op: "feed.post", origin: "cli", params: { type: kind === "notice" ? "notice" : "request", kind, title: "t", ...(prompt ? { prompt } : {}), ...key, ...expiry } }
  }
  if (x < 0.55) {
    const [p, origin] = pick(users)
    const answer = pick([{ decision: "allow" }, { decision: "deny" }, { confirmed: true }, { answers: { db: { selected: ["pg"] }, feat: { selected: ["auth"] } } }])
    return { p, op: "feed.answer", origin, params: { item: anyId(), answer } }
  }
  if (x < 0.65) {
    const [p, origin] = r() < 0.5 ? pick(users) : ([pick(posters), "cli"] as [Principal, Origin])
    return { p, op: "feed.cancel", origin, params: { item: anyId(), ...(r() < 0.5 ? { reason: pick(["poster", "declined", "answered_elsewhere"]) } : {}) } }
  }
  if (x < 0.85) {
    const op = pick(["feed.read", "feed.seen", "feed.archive", "feed.unarchive", "feed.snooze"])
    const params = op === "feed.read" && r() < 0.2 ? { all: true } : { items: [anyId()], ...(op === "feed.snooze" ? { until: now + 1000 + Math.floor(r() * 20_000) } : {}) }
    return { p: pick([mac, phone]), op, origin: "user", params }
  }
  const op = pick(["feed.expire", "feed.snooze_wake", "feed.prune", "feed.push_due"])
  if (op === "feed.push_due") {
    const due = Object.values(s.items).filter((i) => i.push_due_at !== null && i.push_due_at <= now).map((i) => i.id)
    return { p: system, op, origin: "script", params: { at: now, send: due.filter(() => r() < 0.5), skip: due.filter(() => r() < 0.5) } }
  }
  return { p: system, op, origin: "script", params: op === "feed.prune" ? { before: now - Math.floor(r() * 30_000) } : { at: now } }
}

const simulate = (seed: number, steps: number) => {
  const r = rng(seed)
  let state = feedDomain.initial()
  let now = 1_000_000
  const log: Array<LogEntry> = []
  let committed = 0
  for (let n = 0; n < steps; n++) {
    now += Math.floor(r() * 4000)
    const o = randomOp(r, state, now)
    const tx = `s${seed}t${n}`
    const res = run(state, o.p, o.op, o.params, now, tx, o.origin)
    if (!res.ok) continue
    try {
      check(res.state, state)
    } catch (e) {
      throw new Error(`seed ${seed} step ${n} ${o.op}: ${(e as Error).message}`)
    }
    // Like the engine: only a changing op commits its state.
    if (res.changed) {
      log.push({ ...o, now, tx })
      committed++
      state = res.state
    }
  }
  return { state, log, committed }
}

describe("feed reducer invariants on random op sequences", () => {
  const SEEDS = Number(process.env.FEED_SEEDS ?? 200)
  it(`holds I1-I7 for ${SEEDS} seeds and commits real work`, () => {
    let committed = 0
    for (let seed = 1; seed <= SEEDS; seed++) committed += simulate(seed, 150).committed
    expect(committed).toBeGreaterThan(SEEDS * 20)
  }, 120_000)

  it("replays the committed log to the same state (mirror replay is deterministic)", () => {
    for (let seed = 1; seed <= 40; seed++) {
      const { state, log } = simulate(seed, 150)
      // A mirror sees only what an event carries: the projected actor, JSON params, origin, at and tx.
      let replay = feedDomain.initial()
      for (const e of log) {
        const wire = JSON.parse(JSON.stringify({ actor: eventActor(e.p), params: e.params }))
        const res = feedDomain.reduce(replay, e.op, wire.params, { principal: wire.actor, origin: e.origin, now: e.now, tx: e.tx, newId: idFactory(e.tx) })
        if (!res.ok) throw new Error(`seed ${seed}: replay rejected ${e.op}: ${res.code}`)
        replay = res.state
      }
      expect(replay).toEqual(state)
    }
  }, 120_000)
})
