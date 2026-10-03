import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { ProjectionClient } from "../src/client.ts"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain, OwnerFrame } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

interface Head {
  readonly invites: Record<string, { readonly token_hash: string; readonly to: string }>
}
type P = { id: string; token_hash: string; to: string }
const keys: Array<string | undefined> = []
const invites: Domain<Head, P> = {
  initial: () => ({ invites: {} }),
  reduce: (s, _op, p, ctx) => {
    keys.push(ctx.idempotencyKey)
    return {
      ok: true,
      state: { invites: { ...s.invites, [p.id]: { token_hash: p.token_hash, to: p.to } } },
      value: null,
      writes: [{ table: "inv", op: "upsert", key: p.id, n: Object.keys(s.invites).length + 1, row: { token_hash: p.token_hash, to: p.to } }]
    }
  }
}
const stripHash = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(stripHash)
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).filter(([k]) => k !== "token_hash").map(([k, x]) => [k, stripHash(x)]))
  return v
}

describe("event redaction and the idempotency key in the reducer context (lane 15 Q3, Q4)", () => {
  it("keeps token hashes with the owner and out of events, effects and snapshots", () => {
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), invites, {
      stream: "conv:r",
      rowMode: { snapshotTable: "inv", snapshotTail: 10 },
      redact: { params: (_op, p) => stripHash(p), state: stripHash, row: (_t, r) => stripHash(r) }
    })
    const out: Array<OwnerFrame> = []
    e.submit({ identity: "a" }, { t: "op", op: "invite.create", params: { id: "inv_1", token_hash: "SECRETHASH", to: "addr_1" }, idempotency_key: "k1" }, (_t, f) => out.push(f))
    const wire = JSON.stringify([out, e.eventsAfter(0), e.snapshot("a", ["k1"])])
    expect(wire).not.toContain("SECRETHASH")
    expect(wire).toContain("addr_1")
    expect(e.currentState.invites.inv_1!.token_hash).toBe("SECRETHASH")
    expect(e.rows.get<{ token_hash: string }>("inv", "inv_1")!.row.token_hash).toBe("SECRETHASH")
    expect(keys.at(-1)).toBe("k1")
  })

  it("never sends writes of private tables (keys may be secrets)", () => {
    const d: Domain<{ n: number }, { k: string }> = {
      initial: () => ({ n: 0 }),
      reduce: (s, _op, p) => ({ ok: true, state: { n: s.n + 1 }, value: null, writes: [{ table: "inv", op: "upsert", key: "inv_1", n: s.n + 1, row: {} }, { table: "invhash", op: "upsert", key: p.k, n: null, row: { invite_id: "inv_1" } }] })
    }
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), d, { stream: "c", rowMode: { snapshotTable: "inv", snapshotTail: 5 }, redact: { privateTables: ["invhash"] } })
    const out: Array<OwnerFrame> = []
    e.submit({ identity: "a" }, { t: "op", op: "x", params: { k: "TOKENHASHKEY" }, idempotency_key: "k" }, (_t, f) => out.push(f))
    const event = out.find((f) => f.t === "event")
    expect(event && event.t === "event" ? event.effects?.writes.map((w) => w.table) : []).toEqual(["inv"])
    expect(JSON.stringify(e.eventsAfter(0).map((x) => x.effects))).not.toContain("TOKENHASHKEY")
    expect(e.rows.get("invhash", "TOKENHASHKEY")).toBeDefined()
  })

  it("refuses redaction without row mode (JSON mirrors replay params)", () => {
    expect(() => new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), invites, { stream: "x", redact: { params: (_o, p) => p } })).toThrow(/rowMode/)
  })

  it("gives the key to the client's own intent preview and not to mirror replay", () => {
    const json: Domain<{ n: number }, { v: number }> = {
      initial: () => ({ n: 0 }),
      reduce: (s, _op, p, ctx) => {
        keys.push(ctx.idempotencyKey)
        return { ok: true, state: { n: s.n + p.v }, value: null }
      }
    }
    const client = new ProjectionClient(json, { identity: "a" }, () => {}, {}, "a")
    keys.length = 0
    const key = client.issue("add", { v: 1 })
    client.view()
    expect(keys).toContain(key)
    keys.length = 0
    client.receive({ t: "event", stream: "s", seq: 1, tx: "tx", op: "add", params: { v: 1 }, actor: { identity: "a" }, origin: "user", at: 0 })
    expect(keys).toEqual([undefined])
  })

  it("eventsNotReplayed allows param redaction without row mode, and scrubs older stored events once", () => {
    const db = new DatabaseSync(":memory:")
    const plain: Domain<Head, P> = { ...invites, reduce: (s, op, p, ctx) => ({ ...(invites.reduce(s, op, p, ctx) as object), writes: [] }) as never }
    const before = new OwnerEngine(sqliteStore(db), plain, { stream: "feed:x" })
    before.submit({ identity: "a" }, { t: "op", op: "feed.post", params: { id: "i1", token_hash: "OLDTEXT", to: "x" }, idempotency_key: "k1" }, () => {})
    expect(JSON.stringify(before.eventsAfter(0))).toContain("OLDTEXT")
    expect(() => new OwnerEngine(sqliteStore(db), plain, { stream: "feed:x", redact: { params: () => ({}) } })).toThrow()
    const after = new OwnerEngine(sqliteStore(db), plain, { stream: "feed:x", eventsNotReplayed: true, redact: { params: (_op, p) => stripHash(p) } })
    expect(after.scrubStoredParams("feed.post", "v1")).toBe(1)
    expect(after.scrubStoredParams("feed.post", "v1")).toBe(0)
    after.submit({ identity: "a" }, { t: "op", op: "feed.post", params: { id: "i2", token_hash: "NEWTEXT", to: "x" }, idempotency_key: "k2" }, () => {})
    const log = JSON.stringify(after.eventsAfter(0))
    expect(log).not.toContain("OLDTEXT")
    expect(log).not.toContain("NEWTEXT")
  })

  it("a later scrub catches events a stale (non-redacting) build wrote after an earlier scrub", () => {
    const db = new DatabaseSync(":memory:")
    const plain: Domain<Head, P> = { ...invites, reduce: (s, op, p, ctx) => ({ ...(invites.reduce(s, op, p, ctx) as object), writes: [] }) as never }
    const redacting = () => new OwnerEngine(sqliteStore(db), plain, { stream: "feed:x", eventsNotReplayed: true, redact: { params: (_op, p) => stripHash(p) } })
    const first = redacting()
    first.submit({ identity: "a" }, { t: "op", op: "feed.post", params: { id: "i1", token_hash: "AAA", to: "x" }, idempotency_key: "k1" }, () => {})
    expect(first.scrubStoredParams("feed.post", "v2")).toBe(0)
    // A stale deploy without the redaction writes full text after the marker.
    const stale = new OwnerEngine(sqliteStore(db), plain, { stream: "feed:x" })
    stale.submit({ identity: "a" }, { t: "op", op: "feed.post", params: { id: "i2", token_hash: "STALETEXT", to: "x" }, idempotency_key: "k2" }, () => {})
    expect(JSON.stringify(stale.eventsAfter(0))).toContain("STALETEXT")
    const again = redacting()
    expect(again.scrubStoredParams("feed.post", "v2")).toBe(1)
    expect(JSON.stringify(again.eventsAfter(0))).not.toContain("STALETEXT")
    expect(again.scrubStoredParams("feed.post", "v2")).toBe(0)
  })
})
