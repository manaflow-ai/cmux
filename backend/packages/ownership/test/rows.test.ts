/**
 * Row mode (lane 15 need E1) under the same faults as the convergence model:
 * reordered and duplicated delivery, disconnects, crashes inside the commit and
 * owner restarts. Extra invariants for rows:
 *   RowsMatchLog       the owner's row table equals the writes of its committed events
 *   MirrorRowsNotStale every row a mirror holds equals the owner's row at the mirror's seq
 *   HeadIsPrefix       a mirror's head equals the owner's head at the mirror's seq
 * plus NoDoubleApply, NoLostAck and Convergence at quiescence.
 */
import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { ProjectionClient, type ClientOut } from "../src/client.ts"
import { canonicalJson, OwnerEngine } from "../src/engine.ts"
import { MemoryRows } from "../src/rows.ts"
import type { Domain, OwnerFrame } from "../src/types.ts"
import { rng, sqliteStore, Violation } from "./harness.ts"

interface Head {
  readonly last: number
  readonly count: number
}
type Params = { id: string; text?: string }

const logDomain: Domain<Head, Params> = {
  initial: () => ({ last: 0, count: 0 }),
  reduce: (head, op, p, ctx) => {
    const cur = ctx.rows!.get<{ text: string }>("msg", p.id)
    if (op === "add") {
      if (cur) return { ok: false, code: "exists", message: "exists" }
      const n = head.last + 1
      return { ok: true, state: { last: n, count: head.count + 1 }, value: n, writes: [{ table: "msg", op: "upsert", key: p.id, n, row: { text: p.text } }] }
    }
    if (!cur) return { ok: false, code: "selector.not_found", message: "gone" }
    if (op === "edit") return { ok: true, state: head, value: null, writes: [{ table: "msg", op: "upsert", key: p.id, n: cur.n, row: { text: p.text } }] }
    if (op === "remove") return { ok: true, state: { ...head, count: head.count - 1 }, value: null, writes: [{ table: "msg", op: "delete", key: p.id }] }
    return { ok: false, code: "validation.invalid", message: op }
  }
}

const runRowSim = (seed: number, steps = 90) => {
  const r = rng(seed)
  const db = new DatabaseSync(":memory:")
  const sql = sqliteStore(db)
  let crashArmed = false
  let dead = false
  let faults = 0
  const make = () =>
    new OwnerEngine(sql, logDomain, {
      stream: "conv:test",
      prefix: "conv_",
      rowMode: { snapshotTable: "msg", snapshotTail: 3 },
      now: () => 0,
      beforeCommit: () => {
        if (crashArmed) {
          crashArmed = false
          throw new Error("crash")
        }
      }
    })
  let engine = make()
  const ids = ["c0", "c1"]
  const toOwner: Array<{ from: number; msg: ClientOut }> = []
  const toClient: Array<Array<OwnerFrame>> = ids.map(() => [])
  const clients = ids.map((id, i) => new ProjectionClient<Head, Params>(logDomain, { identity: id, install: id }, (msg) => toOwner.push({ from: i, msg }), {}, id))
  const deliver = (target: string, f: OwnerFrame) =>
    ids.forEach((id, i) => {
      if ((target === "all" || target === id) && clients[i]!.connected) toClient[i]!.push(f)
    })

  const events = () => engine.eventsAfter(0, 1_000_000)
  const rowsAt = (k: number) => {
    const m = new MemoryRows()
    for (const e of events().slice(0, k)) m.apply(e.effects?.writes ?? [])
    return m.dump().msg ?? {}
  }
  const ownerRows = () => {
    const m: Record<string, unknown> = {}
    for (const row of engine.rows.range("msg", { limit: 1000 })) m[row.key] = { key: row.key, n: row.n, row: row.row }
    return m
  }
  const check = () => {
    const evs = events()
    if (new Set(evs.map((e) => e.tx)).size !== evs.length) throw new Violation("NoDoubleApply", "tx twice")
    if (canonicalJson(ownerRows()) !== canonicalJson(rowsAt(evs.length))) throw new Violation("RowsMatchLog", "row table differs from committed writes")
    clients.forEach((c, i) => {
      const atK = rowsAt(c.confirmed.seq)
      for (const [k, held] of Object.entries(c.rows.dump().msg ?? {})) {
        if (canonicalJson(held) !== canonicalJson((atK as Record<string, unknown>)[k])) throw new Violation("MirrorRowsNotStale", `client ${ids[i]} row ${k}`)
      }
      const head = evs.slice(0, c.confirmed.seq).reduce<Head>((h, e) => (e.effects?.state as Head) ?? h, logDomain.initial())
      if (canonicalJson(head) !== canonicalJson(c.confirmed.state)) throw new Violation("HeadIsPrefix", `client ${ids[i]}`)
      for (const key of c.settledOk) if (!evs.some((e) => e.tx === engine.txTag(ids[i]!, key))) throw new Violation("NoLostAck", key)
    })
  }

  const ownerStep = (keep: boolean) => {
    if (dead || toOwner.length === 0) return
    const idx = r.int(toOwner.length)
    const m = toOwner[idx]!
    if (!keep) toOwner.splice(idx, 1)
    const id = ids[m.from]!
    if (m.msg.t === "snapshot.request") {
      if (clients[m.from]!.connected) toClient[m.from]!.push(engine.snapshot(id, m.msg.pending))
      return
    }
    try {
      engine.submit({ identity: id, install: id }, m.msg.frame, deliver)
    } catch {
      dead = true
    }
  }
  const clientStep = (i: number, keep: boolean) => {
    const ch = toClient[i]!
    if (ch.length === 0 || !clients[i]!.connected) return
    const idx = r.int(ch.length)
    const f = ch[idx]!
    if (!keep) ch.splice(idx, 1)
    clients[i]!.receive(f)
  }
  const restart = () => {
    engine = make()
    dead = false
    toOwner.length = 0
    toClient.forEach((c) => (c.length = 0))
    clients.forEach((c) => c.disconnect())
  }
  let next = 0
  for (let s = 0; s < steps; s++) {
    const i = r.int(2)
    const c = clients[i]!
    const roll = r.next()
    if (roll < 0.2 && c.connected) {
      const kind = r.int(3)
      const id = `m${r.int(4)}`
      c.issue(kind === 0 ? "add" : kind === 1 ? "edit" : "remove", { id, text: `t${next++}` })
    } else if (roll < 0.24 && c.connected && faults < 3) {
      faults++
      c.disconnect()
      toClient[i]!.length = 0
      for (let k = toOwner.length - 1; k >= 0; k--) if (toOwner[k]!.from === i) toOwner.splice(k, 1)
    } else if (roll < 0.3 && !c.connected && !dead) c.reconnect()
    else if (roll < 0.33 && faults < 3 && !dead) {
      faults++
      crashArmed = true
    } else if (roll < 0.36 && dead) restart()
    else if (roll < 0.66) ownerStep(r.chance(0.25))
    else clientStep(i, r.chance(0.25))
    check()
  }
  crashArmed = false
  if (dead) restart()
  clients.forEach((c) => !c.connected && c.reconnect())
  for (let g = 0; g < 50_000 && (toOwner.length || toClient.some((c) => c.length)); g++) {
    if (toOwner.length) ownerStep(false)
    else clientStep(toClient.findIndex((c) => c.length > 0), false)
    check()
  }
  clients.forEach((c, i) => {
    if (c.pending.length || c.confirmed.seq !== engine.currentSeq) throw new Violation("Convergence", `client ${ids[i]} not converged`)
    if (canonicalJson(c.confirmed.state) !== canonicalJson(engine.currentState)) throw new Violation("Convergence", "head differs")
  })
  db.close()
  return engine.currentSeq
}

describe("row-backed domains (E1)", () => {
  it("keep rows, heads and mirrors consistent under faults (300 seeds)", () => {
    let committed = 0
    for (let seed = 1; seed <= 300; seed++) {
      try {
        committed += runRowSim(seed)
      } catch (e) {
        if (e instanceof Violation) throw new Error(`seed ${seed}: ${e.message}`)
        throw e
      }
    }
    expect(committed).toBeGreaterThan(300)
  })

  it("a crash inside the commit writes no rows", () => {
    const db = new DatabaseSync(":memory:")
    const sql = sqliteStore(db)
    let crash = true
    const engine = new OwnerEngine(sql, logDomain, {
      stream: "conv:x",
      rowMode: { snapshotTable: "msg", snapshotTail: 10 },
      beforeCommit: () => {
        if (crash) throw new Error("crash")
      }
    })
    expect(() => engine.submit({ identity: "a" }, { t: "op", op: "add", params: { id: "m1", text: "x" }, idempotency_key: "k" }, () => {})).toThrow()
    crash = false
    expect(engine.rows.get("msg", "m1")).toBeUndefined()
    expect(engine.currentSeq).toBe(0)
    engine.submit({ identity: "a" }, { t: "op", op: "add", params: { id: "m1", text: "x" }, idempotency_key: "k" }, () => {})
    expect(engine.rows.get("msg", "m1")?.row).toEqual({ text: "x" })
    expect(engine.snapshot("a", ["k"]).rows?.rows.map((r) => r.key)).toEqual(["m1"])
  })

  it("two engines with different prefixes in one store are independent streams (E2)", () => {
    const sql = sqliteStore(new DatabaseSync(":memory:"))
    const a = new OwnerEngine(sql, logDomain, { stream: "user:u", prefix: "own_", rowMode: { snapshotTable: "msg", snapshotTail: 5 } })
    const b = new OwnerEngine(sql, logDomain, { stream: "inbox:u", prefix: "inbox_", rowMode: { snapshotTable: "msg", snapshotTail: 5 } })
    a.submit({ identity: "x" }, { t: "op", op: "add", params: { id: "m", text: "a" }, idempotency_key: "k" }, () => {})
    expect(a.currentSeq).toBe(1)
    expect(b.currentSeq).toBe(0)
    expect(b.rows.get("msg", "m")).toBeUndefined()
    b.submit({ identity: "x" }, { t: "op", op: "add", params: { id: "m", text: "b" }, idempotency_key: "k" }, () => {})
    expect(b.rows.get("msg", "m")?.row).toEqual({ text: "b" })
    expect(a.rows.get("msg", "m")?.row).toEqual({ text: "a" })
  })

  it("prunes old events but keeps the newest, and resumes fall back to a snapshot (E3)", () => {
    let now = 0
    const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), logDomain, { stream: "conv:p", now: () => now, rowMode: { snapshotTable: "msg", snapshotTail: 5 } })
    for (let i = 0; i < 20; i++) {
      now = i * 1000
      engine.submit({ identity: "a" }, { t: "op", op: "add", params: { id: `m${i}`, text: "x" }, idempotency_key: `k${i}` }, () => {})
    }
    expect(engine.canReplayFrom(0)).toBe(true)
    expect(engine.pruneEvents(15_000, 5)).toBe(15)
    expect(engine.eventsAfter(0).map((e) => e.seq)).toEqual([16, 17, 18, 19, 20])
    expect(engine.canReplayFrom(14)).toBe(false)
    expect(engine.canReplayFrom(15)).toBe(true)
    expect(engine.pruneEvents(100_000, 5)).toBe(0)
  })
})
