/**
 * Writes schemas/ownership-mirror/vectors.json (repo root): traces of the REAL ProjectionClient
 * (src/client.ts) that every other client of the `cmux.wire/1` ownership protocol must reproduce
 * (plans/cmux-next/object-sync DESIGN.md, phase 1). The Rust stream mirror
 * (cmux-tui/crates/cmux-cloud-wire, tests/mirror_vectors.rs) replays each case.
 *
 * A case is one client: its key prefix and its inputs in order (issue, receive, disconnect,
 * reconnect, retry, expire), with what the client sent for each input (wire frames) and what it
 * holds after it (confirmed seq, state and rows; pending, expired and held keys; awaiting,
 * connected, desyncs, settled keys). Hand cases pin edge cases with hand-built owner frames.
 * Simulated cases run the REAL OwnerEngine (row mode, bun:sqlite) with reordering, duplicates,
 * disconnects, retries and a clock jump past the intent TTL. Everything is seeded and the
 * engine's tag secret is fixed, so the file is deterministic.
 *
 *   bun scripts/export-mirror-vectors.ts          write
 *   bun scripts/export-mirror-vectors.ts --check  fail when the checked-in file differs
 */
import { Database } from "bun:sqlite"
import { readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { INTENT_TTL_MS, OwnerUnreachable, ProjectionClient, type ClientOut } from "../src/client.ts"
import { OwnerEngine, type SqlStore } from "../src/engine.ts"
import type { Domain, EventFrame, OwnerFrame, Principal, SettledFrame, SnapshotFrame } from "../src/types.ts"

type Json = unknown
type Input =
  | { t: "issue"; op: string; params: Json; now: number }
  | { t: "receive"; frame: OwnerFrame }
  | { t: "disconnect" }
  | { t: "reconnect"; now: number }
  | { t: "retry"; key: string; now: number }
  | { t: "expire"; now: number }
interface Step {
  readonly in: Input
  readonly out: Array<Json>
  readonly after: Json
}
interface Case {
  readonly name: string
  readonly note: string
  readonly key_prefix: string
  /** The domain's initial head state: the mirror's confirmed state before any frame. */
  readonly initial: Json
  readonly steps: Array<Step>
}

const wire = (o: ClientOut): Json => (o.t === "op" ? o.frame : o)

/** Drives one ProjectionClient and records every input with its outputs and the state after. */
class Recorder<S> {
  readonly steps: Array<Step> = []
  readonly client: ProjectionClient<S>
  private sent: Array<Json> = []
  private now = 0
  constructor(domain: Domain<S>, principal: Principal, readonly keyPrefix: string) {
    this.client = new ProjectionClient<S>(domain, principal, (o) => this.sent.push(wire(o)), {}, keyPrefix)
    this.client.clock = () => this.now
  }
  private record(input: Input, run: () => void): Array<Json> {
    this.sent = []
    if ("now" in input) this.now = input.now
    try {
      run()
    } catch (e) {
      if (!(e instanceof OwnerUnreachable)) throw e
      this.sent.push({ error: e.code })
    }
    const c = this.client
    const after = {
      seq: c.confirmed.seq,
      state: c.confirmed.state,
      rows: c.rows.dump(),
      pending: c.pending.map((i) => i.idempotency_key),
      expired: c.expired.map((i) => i.idempotency_key),
      held: c.held.map((h) => h.idempotency_key),
      awaiting: c.awaiting,
      connected: c.connected,
      desyncs: c.desyncs,
      settled_ok: [...c.settledOk].sort()
    }
    const out = this.sent
    this.steps.push({ in: input, out, after: JSON.parse(JSON.stringify(after)) })
    return out
  }
  issue(op: string, params: Json, now: number): Array<Json> {
    return this.record({ t: "issue", op, params, now }, () => this.client.issue(op, params))
  }
  receive(frame: OwnerFrame): Array<Json> {
    return this.record({ t: "receive", frame: JSON.parse(JSON.stringify(frame)) as OwnerFrame }, () => this.client.receive(frame))
  }
  disconnect(): Array<Json> {
    return this.record({ t: "disconnect" }, () => this.client.disconnect())
  }
  reconnect(now: number): Array<Json> {
    return this.record({ t: "reconnect", now }, () => this.client.reconnect())
  }
  retry(key: string, now: number): Array<Json> {
    return this.record({ t: "retry", key, now }, () => this.client.retry(key))
  }
  expire(now: number): Array<Json> {
    return this.record({ t: "expire", now }, () => this.client.expireStale())
  }
}

// ------------------------------------------------------------------ hand cases

/** A domain whose reducer refuses everything: hand cases exercise the effects path and the desync path only. */
const opaque: Domain<Json> = { initial: () => ({}), reduce: () => ({ ok: false, code: "opaque", message: "mirror applies effects only" }) }
const me: Principal = { identity: "c", install: "c" }
const S = "conv:hand"
const ev = (seq: number, tx: string, state: Json, writes: Array<Json> = []): EventFrame => ({
  t: "event", stream: S, seq, tx, op: "put", params: {}, actor: me, origin: "user", at: seq, effects: { state, writes: writes as never }
})
const put = (key: string, n: number | null, row: Json) => ({ table: "msg", op: "upsert", key, n, row })
const del = (key: string) => ({ table: "msg", op: "delete", key })
const settled = (key: string, sequence: number, ok = true): SettledFrame => ({ t: "request-settled", tx: `tx-${key}`, idempotency_key: key, stream: S, sequence, ok })
const snap = (seq: number, state: Json, decided: Array<[string, boolean, number]>, rows?: Array<[string, number | null, Json]>): SnapshotFrame<Json> => ({
  t: "snapshot", stream: S, seq, state, decided: decided.map(([idempotency_key, ok, sequence]) => ({ idempotency_key, ok, sequence })),
  ...(rows ? { rows: { table: "msg", rows: rows.map(([key, n, row]) => ({ key, n, row })) } } : {})
})

const hand = (name: string, note: string, run: (r: Recorder<Json>) => void): Case => {
  const r = new Recorder(opaque, me, "c")
  run(r)
  return { name, note, key_prefix: "c", initial: opaque.initial(), steps: r.steps }
}

const handCases: Array<Case> = [
  hand("in_order", "An event at seq+1 applies its effects; the settle after it removes the intent and records it as settled.", (r) => {
    r.issue("message.send", { text: "hi" }, 10)
    r.receive(ev(1, "tx-c:1", { last_seq: 1 }, [put("m1", 1, { text: "hi" })]))
    r.receive({ t: "result", tx: "tx-c:1", idempotency_key: "c:1", value: { seq: 1 }, revision: "1", replayed: false })
    r.receive(settled("c:1", 1))
  }),
  hand("settle_before_event", "An ok settle that arrives before the mirror reaches its sequence is held, then applied with the event (no flicker).", (r) => {
    r.issue("message.send", { text: "a" }, 10)
    r.receive(settled("c:1", 1))
    r.receive(ev(1, "tx-c:1", { last_seq: 1 }, [put("m1", 1, { text: "a" })]))
  }),
  hand("reject_settles_at_once", "A failed settle removes the intent at once, with no sequence wait and no settled record.", (r) => {
    r.issue("message.edit", { id: "m9" }, 10)
    r.receive({ t: "reject", tx: "tx-c:1", idempotency_key: "c:1", code: "not_found", message: "gone", retryable: false, replayed: false })
    r.receive(settled("c:1", 0, false))
  }),
  hand("gap_then_snapshot", "A gap buffers the event and asks for a snapshot with the pending keys; events during the wait buffer; the snapshot settles decided keys and replays the buffer.", (r) => {
    r.issue("message.send", { text: "x" }, 10)
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" })]))
    r.receive(ev(3, "tx-o3", { last_seq: 3 }, [put("m3", 3, { text: "o3" })]))
    r.receive(ev(4, "tx-o4", { last_seq: 4 }, [put("m4", 4, { text: "o4" })]))
    r.receive(snap(2, { last_seq: 2 }, [["c:1", true, 2]], [["m1", 1, { text: "o1" }], ["m2", 2, { text: "x" }]]))
  }),
  hand("duplicate_and_old_events", "Events at or below the confirmed seq are ignored.", (r) => {
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" })]))
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" })]))
    r.receive(ev(2, "tx-o2", { last_seq: 2 }, [del("m1")]))
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" })]))
  }),
  hand("offline_refuses_new_ops", "Disconnected: a new op is refused (U5), frames are ignored; reconnect resends the pending intent with its key and asks for a snapshot.", (r) => {
    r.issue("message.send", { text: "before" }, 10)
    r.disconnect()
    r.issue("message.send", { text: "while offline" }, 20)
    r.receive(ev(1, "tx-c:1", { last_seq: 1 }, [put("m1", 1, { text: "before" })]))
    r.reconnect(30)
    r.receive(snap(1, { last_seq: 1 }, [["c:1", true, 1]], [["m1", 1, { text: "before" }]]))
  }),
  hand("lost_reply_settled_by_snapshot", "A reply lost across a reconnect is settled by the snapshot's decided list; a failed decision leaves no settled record.", (r) => {
    r.issue("message.send", { text: "one" }, 10)
    r.issue("message.retract", { id: "m0" }, 11)
    r.disconnect()
    r.reconnect(12)
    r.receive(snap(1, { last_seq: 1 }, [["c:1", true, 1], ["c:2", false, 0]], [["m1", 1, { text: "one" }]]))
  }),
  hand("older_snapshot_keeps_state", "A snapshot older than the confirmed seq does not replace state or settle keys, but the buffered events still replay.", (r) => {
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" })]))
    r.receive(ev(2, "tx-o2", { last_seq: 2 }, [put("m2", 2, { text: "o2" })]))
    r.receive(ev(4, "tx-o4", { last_seq: 4 }, [put("m4", 4, { text: "o4" })]))
    r.receive(snap(1, { last_seq: 1 }, [], [["m1", 1, { text: "o1" }]]))
    r.receive(ev(3, "tx-o3", { last_seq: 3 }, [put("m3", 3, { text: "o3" })]))
  }),
  hand("snapshot_replaces_rows", "A snapshot with rows replaces the rows held before; one without rows keeps them.", (r) => {
    r.receive(ev(1, "tx-o1", { last_seq: 1 }, [put("m1", 1, { text: "o1" }), put("p1", null, { pin: true })]))
    r.disconnect()
    r.reconnect(5)
    r.receive(snap(3, { last_seq: 3 }, [], [["m3", 3, { text: "o3" }]]))
    r.disconnect()
    r.reconnect(6)
    r.receive(snap(4, { last_seq: 4 }, []))
  }),
  hand("event_without_effects_desyncs", "A mirror without a reducer for the op counts a desync and asks for a snapshot instead of guessing.", (r) => {
    r.receive({ t: "event", stream: S, seq: 1, tx: "tx-o1", op: "title.set", params: { title: "t" }, actor: me, origin: "user", at: 1 })
    r.receive(snap(1, { last_seq: 1, title: "t" }, []))
  }),
  hand("retry_resends_same_key", "A timeout retry resends the same frame with the same key; an unknown key sends nothing.", (r) => {
    r.issue("reaction.add", { id: "m1", reaction: "+1" }, 10)
    r.retry("c:1", 20)
    r.retry("c:9", 21)
  }),
  hand("intent_ttl", "An intent older than the TTL moves to expired and is never resent; the snapshot request still asks about it, and a decided answer clears it.", (r) => {
    r.issue("message.send", { text: "old" }, 0)
    r.issue("message.send", { text: "new" }, INTENT_TTL_MS)
    r.disconnect()
    r.reconnect(INTENT_TTL_MS + 1)
    r.receive(snap(1, { last_seq: 1 }, [["c:1", true, 1]], [["m1", 1, { text: "old" }]]))
    r.expire(3 * INTENT_TTL_MS)
  })
]

// ------------------------------------------------------------------ simulated cases (real OwnerEngine)

interface ListState {
  readonly title: string
  readonly next: number
}
/** A row-mode domain: put appends a row with the next order, del deletes, title edits the head, noop changes nothing, bad rejects. */
const listDomain: Domain<ListState, { key?: string; text?: string; title?: string }> = {
  initial: () => ({ title: "", next: 1 }),
  reduce: (st, op, p, ctx) => {
    if (op === "put") {
      const key = p.key ?? ctx.newId("row")
      const existing = ctx.rows?.get("item", key)
      if (existing) return { ok: true, state: st, value: { key }, writes: [{ table: "item", op: "upsert", key, n: existing.n, row: { text: p.text ?? "" } }] }
      return { ok: true, state: { ...st, next: st.next + 1 }, value: { key }, writes: [{ table: "item", op: "upsert", key, n: st.next, row: { text: p.text ?? "" } }] }
    }
    if (op === "del") {
      if (!p.key || !ctx.rows?.get("item", p.key)) return { ok: false, code: "not_found", message: "no such row" }
      return { ok: true, state: st, value: null, writes: [{ table: "item", op: "delete", key: p.key }] }
    }
    if (op === "title") return { ok: true, state: { ...st, title: p.title ?? "" }, value: null }
    if (op === "noop") return { ok: true, state: st, value: null, changed: false }
    return { ok: false, code: "validation.invalid", message: `unknown op ${op}` }
  }
}

const rng = (seed: number) => {
  let s = seed >>> 0 || 1
  const next = () => {
    s ^= s << 13
    s ^= s >>> 17
    s ^= s << 5
    return (s >>> 0) / 0x100000000
  }
  return { next, int: (n: number) => Math.floor(next() * n), chance: (p: number) => next() < p }
}

const bunStore = (db: Database): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => db.prepare(q).all(...(params as Array<never>)) as Array<T>,
  transaction: <T>(fn: () => T): T => db.transaction(fn)()
})

const simulate = (seed: number, steps: number): Array<Case> => {
  const r = rng(seed)
  const db = new Database(":memory:")
  const sql = bunStore(db)
  let now = 1_000
  const options = { stream: `list:sim${seed}`, now: () => now, rowMode: { snapshotTable: "item", snapshotTail: 4 } }
  new OwnerEngine(sql, listDomain, options)
  sql.exec(`UPDATE own_meta SET value = 'fixed-test-secret' WHERE key = 'tx_secret'`)
  const engine = new OwnerEngine(sql, listDomain, options)
  const ids = ["a", "b"]
  const recs = ids.map((id) => new Recorder<ListState>(listDomain as unknown as Domain<ListState>, { identity: id, install: id }, id))
  const toOwner: Array<{ from: number; msg: Json }> = []
  const toClient: Array<Array<OwnerFrame>> = ids.map(() => [])
  const queue = (i: number, out: Array<Json>) => {
    for (const m of out) if (!(m as { error?: string }).error) toOwner.push({ from: i, msg: m })
  }
  const deliver = (target: "all" | string, frame: OwnerFrame) =>
    ids.forEach((id, i) => {
      if ((target === "all" || target === id) && recs[i]!.client.connected) toClient[i]!.push(frame)
    })
  const ops = () => {
    const k = r.int(10)
    return k < 4 ? { op: "put", params: { text: `t${r.int(100)}` } } : k < 6 ? { op: "put", params: { key: `k${r.int(3)}`, text: `e${r.int(9)}` } } : k < 7 ? { op: "del", params: { key: `k${r.int(3)}` } } : k < 8 ? { op: "title", params: { title: `T${r.int(9)}` } } : k < 9 ? { op: "noop", params: {} } : { op: "bad", params: {} }
  }
  let jumped = false
  for (let step = 0; step < steps; step++) {
    const i = r.int(ids.length)
    const rec = recs[i]!
    const roll = r.next()
    now += 1 + r.int(50)
    if (!jumped && step === Math.floor(steps / 2) && r.chance(0.5)) {
      now += INTENT_TTL_MS + 1
      jumped = true
    }
    if (roll < 0.18 && rec.client.connected) {
      const o = ops()
      queue(i, rec.issue(o.op, o.params, now))
    } else if (roll < 0.22 && rec.client.pending.length > 0) {
      queue(i, rec.retry(rec.client.pending[r.int(rec.client.pending.length)]!.idempotency_key, now))
    } else if (roll < 0.26 && rec.client.connected) {
      rec.disconnect()
      toClient[i]!.length = 0
      for (let k = toOwner.length - 1; k >= 0; k--) if (toOwner[k]!.from === i) toOwner.splice(k, 1)
    } else if (roll < 0.33 && !rec.client.connected) {
      queue(i, rec.reconnect(now))
    } else if (roll < 0.66 && toOwner.length > 0) {
      const idx = r.int(toOwner.length)
      const m = toOwner[idx]!
      if (!r.chance(0.15)) toOwner.splice(idx, 1)
      const id = ids[m.from]!
      const msg = m.msg as { t: string; pending?: Array<string> }
      if (msg.t === "snapshot.request") {
        if (recs[m.from]!.client.connected) toClient[m.from]!.push(engine.snapshot(id, msg.pending))
      } else engine.submit({ identity: id, install: id }, msg as never, deliver)
    } else if (toClient[i]!.length > 0 && rec.client.connected) {
      const ch = toClient[i]!
      const idx = r.int(ch.length)
      const f = ch[idx]!
      if (!r.chance(0.15)) ch.splice(idx, 1)
      queue(i, rec.receive(f))
    }
  }
  // Heal: reconnect everyone, then deliver fairly until quiet, so each trace ends converged.
  recs.forEach((rec, i) => {
    if (!rec.client.connected) queue(i, rec.reconnect(now))
  })
  for (let guard = 0; guard < 10_000; guard++) {
    if (toOwner.length > 0) {
      const m = toOwner.shift()!
      const id = ids[m.from]!
      const msg = m.msg as { t: string; pending?: Array<string> }
      if (msg.t === "snapshot.request") toClient[m.from]!.push(engine.snapshot(id, msg.pending))
      else engine.submit({ identity: id, install: id }, msg as never, deliver)
      continue
    }
    const busy = toClient.findIndex((ch) => ch.length > 0)
    if (busy < 0) break
    queue(busy, recs[busy]!.receive(toClient[busy]!.shift()!))
  }
  recs.forEach((rec, i) => {
    if (rec.client.confirmed.seq !== engine.currentSeq || rec.client.pending.length > 0) throw new Error(`sim ${seed}: client ${ids[i]} did not converge`)
  })
  db.close()
  return recs.map((rec, i) => ({
    name: `sim_${seed}_${ids[i]}`,
    note: `Client ${ids[i]} of a seeded run against the real OwnerEngine (row mode, tail 4): reordering, 15% duplicates, disconnects, retries${jumped ? ", a clock jump past the intent TTL" : ""}; ends converged at seq ${engine.currentSeq}.`,
    key_prefix: ids[i]!,
    initial: listDomain.initial(),
    steps: rec.steps
  }))
}

const simCases = [11, 29, 47, 83, 131, 197].flatMap((seed) => simulate(seed, 160))
const cases = [...handCases, ...simCases]

const doc = {
  description:
    "Traces of the cmux.wire/1 ownership client (backend/packages/ownership/src/client.ts, ProjectionClient) that every client implementation must reproduce: for each input, the frames sent (`op` frames and `snapshot.request {pending}`; `{error: owner_unreachable}` when an op is refused offline) and the client after it. Clients apply event effects and snapshots, detect gaps, hold early settles, resend pending intents on reconnect, expire intents after intent_ttl_ms. `rows` is {table: {key: {key, n, row}}}. Generated by backend/packages/ownership/scripts/export-mirror-vectors.ts.",
  version: 1,
  intent_ttl_ms: INTENT_TTL_MS,
  cases
}
const out = fileURLToPath(new URL("../../../../schemas/ownership-mirror/vectors.json", import.meta.url))
// One case per line: the file stays diffable per case without a multi-megabyte pretty print.
const text = `{"description":${JSON.stringify(doc.description)},"version":${doc.version},"intent_ttl_ms":${doc.intent_ttl_ms},"cases":[\n${cases.map((c) => JSON.stringify(c)).join(",\n")}\n]}\n`
if (process.argv.includes("--check")) {
  let current = ""
  try {
    current = readFileSync(out, "utf8")
  } catch {}
  if (current !== text) {
    console.error(`ownership mirror vectors out of date: run bun scripts/export-mirror-vectors.ts (${out})`)
    process.exit(1)
  }
  console.log(`ownership mirror vectors ok: ${cases.length} cases`)
} else {
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, text)
  console.log(`wrote ${out}: ${cases.length} cases, ${cases.reduce((n, c) => n + c.steps.length, 0)} steps`)
}
