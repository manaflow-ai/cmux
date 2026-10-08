import { DatabaseSync } from "node:sqlite"
import { OwnerEngine, type Domain, type OwnerFrame, type SqlStore } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { Principal } from "../src/conversation/engine-types.ts"
import {
  dmPeer,
  INBOX_PRIVATE_TABLES,
  inboxDomain,
  inboxReindexBatches,
  listInbox,
  pageInbox,
  TABLE_ENTRY,
  TABLE_ORDER,
  TABLE_PEER,
  type InboxBumpParams,
  type InboxEntry,
  type InboxHead
} from "../src/inbox/index.ts"

/**
 * inbox.list paging (home-messaging.md section 4.2, home-scale.md B5): a keyset cursor over
 * pinned-first, then last_at newest first, then conversation id, read through an ordered index
 * table so a page costs about one page of rows, not the whole inbox.
 */

const SYSTEM: Principal = { identity: "system:conv", kind: "system" }
const USER: Principal = { identity: "session:user_alice", user: "user_alice", kind: "session" }
const NOW = Date.UTC(2026, 9, 3, 12)

interface CountingStore extends SqlStore {
  rowsRead: number
}

const store = (): CountingStore => {
  const db = new DatabaseSync(":memory:")
  const s: CountingStore = {
    rowsRead: 0,
    exec: <T>(q: string, ...params: Array<unknown>) => {
      const rows = db.prepare(q).all(...(params as Array<never>)) as Array<T>
      s.rowsRead += rows.length
      return rows
    },
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
    }
  }
  return s
}

const conv = (i: number) => `conv_${String(i).padStart(26, "0")}`
const at = (second: number) => new Date(Date.UTC(2026, 9, 1) + second * 1000).toISOString()

const bump = (conversation: string, rev: number, second: number, extra: Partial<InboxBumpParams> = {}): InboxBumpParams => ({
  user: "user_alice",
  conversation,
  rev,
  kind: "group",
  title: conversation,
  last_seq: rev,
  last_at: at(second),
  preview: "",
  ...extra
})

const open = (sql: CountingStore = store()) => {
  const engine = new OwnerEngine<InboxHead>(sql, inboxDomain as Domain<InboxHead>, {
    stream: "inbox:user_alice",
    prefix: "inbox_",
    rowMode: { snapshotTable: TABLE_ENTRY, snapshotTail: 0 },
    redact: { privateTables: INBOX_PRIVATE_TABLES }
  })
  const run = (principal: Principal, op: string, params: unknown, key: string) => {
    const frames: Array<OwnerFrame> = []
    engine.submit(principal, { t: "op", op, params, idempotency_key: key }, (_target, f) => frames.push(f))
    const reply = frames.find((f) => f.t === "result" || f.t === "reject")
    if (reply?.t !== "result") throw new Error(`${op} ${key}: ${reply && "code" in reply ? reply.code : "no reply"}`)
    return reply
  }
  return { sql, engine, run }
}

/** Rewrites stored state as the code before the order index left it: no order rows, no `ordered` flag. */
const makeLegacy = (sql: CountingStore) => {
  sql.exec(`DELETE FROM inbox_rows WHERE tbl = ?`, TABLE_ORDER)
  const head = JSON.parse(sql.exec<{ json: string }>(`SELECT json FROM inbox_state WHERE id = 1`)[0]!.json) as Record<string, unknown>
  delete head.ordered
  sql.exec(`UPDATE inbox_state SET json = ? WHERE id = 1`, JSON.stringify(head))
}

const eventCount = (sql: CountingStore) => sql.exec<{ c: number }>(`SELECT COUNT(*) AS c FROM inbox_events`)[0]!.c

const allPages = (rows: Parameters<typeof pageInbox>[0], query: { include_archived?: boolean; limit?: number } = {}) => {
  const seen: Array<string> = []
  let cursor: string | undefined
  for (let guard = 0; guard < 100; guard++) {
    const page = pageInbox(rows, { limit: query.limit ?? 200, include_archived: query.include_archived, ...(cursor === undefined ? {} : { cursor }) })
    seen.push(...page.entries.map((e) => e.conversation))
    if (page.next_cursor === null) return seen
    cursor = page.next_cursor
  }
  throw new Error("paging did not end")
}

describe("inbox.list paging", () => {
  it("pages 450 entries by 200 in list order: pinned by position, then newest first, ties by id; archived and removed apart", () => {
    const { engine, run } = open()
    for (let i = 0; i < 450; i++) {
      // Every third pair shares a last_at, so ties fall back to the conversation id.
      run(SYSTEM, "inbox.bump", bump(conv(i), 1, Math.floor(i / 2) * 7 + (i % 5)), `bump:${i}:1`)
    }
    run(USER, "inbox.pin", { conversation: conv(10), pinned: true }, "pin-10")
    run(USER, "inbox.pin", { conversation: conv(300), pinned: true, position: 0 }, "pin-300")
    run(USER, "inbox.pin", { conversation: conv(5), pinned: true }, "pin-5")
    for (const i of [1, 2, 3, 200, 449]) run(USER, "inbox.archive", { conversation: conv(i), archived: true }, `archive-${i}`)
    run(USER, "inbox.archive", { conversation: conv(5), archived: true }, "archive-5")
    run(SYSTEM, "inbox.bump", bump(conv(7), 2, 0, { removed: true }), "bump:7:2")
    // A newer message moves an entry to the top of the unpinned part.
    run(SYSTEM, "inbox.bump", bump(conv(20), 3, 99_999), "bump:20:3")
    // A newer message un-archives conv 449.
    run(SYSTEM, "inbox.bump", bump(conv(449), 2, 50), "bump:449:2")

    const entries = engine.rows.scan<InboxEntry>(TABLE_ENTRY).map((r) => r.row)
    const expected = listInbox(entries, { limit: 1000 }).map((e) => e.conversation)
    // conv 10 and conv 300 both hold position 0: the id breaks the tie.
    expect(expected.slice(0, 3)).toEqual([conv(10), conv(300), conv(20)])
    expect(expected).not.toContain(conv(7))
    expect(expected).not.toContain(conv(200))
    expect(expected).toContain(conv(449))

    const first = pageInbox(engine.rows, { limit: 200 })
    expect(first.entries.map((e) => e.conversation)).toEqual(expected.slice(0, 200))
    expect(typeof first.next_cursor).toBe("string")
    const pages = allPages(engine.rows)
    expect(pages).toEqual(expected)
    expect(new Set(pages).size).toBe(pages.length)

    const withArchived = listInbox(entries, { limit: 1000, include_archived: true }).map((e) => e.conversation)
    expect(withArchived).toContain(conv(200))
    // conv 5 is pinned and archived: it sorts with the pins when archived entries are shown.
    expect(withArchived.slice(0, 4)).toEqual([conv(10), conv(300), conv(5), conv(20)])
    expect(allPages(engine.rows, { include_archived: true, limit: 37 })).toEqual(withArchived)
  })

  it("reads about one page of rows, not every entry, for a user with 2,000 conversations", () => {
    const { sql, engine, run } = open()
    for (let i = 0; i < 2000; i++) run(SYSTEM, "inbox.bump", bump(conv(i), 1, i), `bump:${i}:1`)
    for (let i = 0; i < 40; i++) run(USER, "inbox.archive", { conversation: conv(1999 - i * 3), archived: true }, `archive-${i}`)
    sql.rowsRead = 0
    const first = pageInbox(engine.rows, { limit: 200 })
    expect(first.entries).toHaveLength(200)
    expect(first.entries[0]!.conversation).toBe(conv(1998))
    expect(sql.rowsRead).toBeLessThanOrEqual(2 * 201)
    sql.rowsRead = 0
    const second = pageInbox(engine.rows, { limit: 200, cursor: first.next_cursor!, include_archived: true })
    expect(second.entries).toHaveLength(200)
    expect(sql.rowsRead).toBeLessThanOrEqual(4 * 201)
  })

  it("refuses a pin position past the safe integer range, which would sort and count wrongly", () => {
    const { engine, run } = open()
    run(SYSTEM, "inbox.bump", bump(conv(1), 1, 1), "bump:1:1")
    run(SYSTEM, "inbox.bump", bump(conv(2), 1, 2), "bump:2:1")
    for (const position of [1e20, Number.MAX_SAFE_INTEGER]) {
      expect(() => run(USER, "inbox.pin", { conversation: conv(1), pinned: true, position }, `pin-${position}`)).toThrow(/invalid_params/)
    }
    run(USER, "inbox.pin", { conversation: conv(1), pinned: true, position: Number.MAX_SAFE_INTEGER - 1 }, "pin-max")
    expect(engine.currentState.next_pin).toBe(Number.MAX_SAFE_INTEGER)
    // The next automatic position would be past the range too.
    expect(() => run(USER, "inbox.pin", { conversation: conv(2), pinned: true }, "pin-auto")).toThrow(/invalid_params/)
  })

  it("an unknown or foreign cursor never fails: it is only a position", () => {
    const { engine, run } = open()
    for (let i = 0; i < 5; i++) run(SYSTEM, "inbox.bump", bump(conv(i), 1, i), `bump:${i}:1`)
    expect(pageInbox(engine.rows, { limit: 200, cursor: "zzz" }).entries).toEqual([])
    expect(pageInbox(engine.rows, { limit: 200, cursor: "" }).entries).toHaveLength(5)
    expect(pageInbox(engine.rows, { limit: 0 })).toEqual({ entries: [], next_cursor: null })
  })

  it("the plain-record list honors the same cursor", () => {
    const { engine, run } = open()
    for (let i = 0; i < 30; i++) run(SYSTEM, "inbox.bump", bump(conv(i), 1, i % 4), `bump:${i}:1`)
    const entries = engine.rows.scan<InboxEntry>(TABLE_ENTRY).map((r) => r.row)
    const page = pageInbox(engine.rows, { limit: 12 })
    expect(listInbox(entries, { limit: 12, cursor: page.next_cursor! }).map((e) => e.conversation)).toEqual(
      pageInbox(engine.rows, { limit: 12, cursor: page.next_cursor! }).entries.map((e) => e.conversation)
    )
  })

  it("the order index stays with the owner: subscriber effects never carry it", () => {
    const { engine, run } = open()
    run(SYSTEM, "inbox.bump", bump(conv(1), 1, 1), "bump:1:1")
    expect(engine.rows.keyRange(TABLE_ORDER, { limit: 10 })).toHaveLength(1)
    expect(INBOX_PRIVATE_TABLES).toContain(TABLE_ORDER)
    const effects = engine.eventsAfter(0).flatMap((e) => (e.t === "event" ? (e.effects?.writes ?? []) : []))
    expect(effects.map((w) => w.table)).toEqual([TABLE_ENTRY])
  })
})

describe("inbox order index migration (inbox.reindex)", () => {
  it("indexes entries written before the order index existed, then lists them by page", () => {
    const sql = store()
    const legacy = open(sql)
    for (let i = 0; i < 450; i++) legacy.run(SYSTEM, "inbox.bump", bump(conv(i), 1, i), `bump:${i}:1`)
    // Model an inbox written by the previous code: no order rows, a head without the flag.
    sql.exec(`DELETE FROM inbox_rows WHERE tbl = ?`, TABLE_ORDER)
    const head = JSON.parse(sql.exec<{ json: string }>(`SELECT json FROM inbox_state WHERE id = 1`)[0]!.json) as Record<string, unknown>
    delete head.ordered
    sql.exec(`UPDATE inbox_state SET json = ? WHERE id = 1`, JSON.stringify(head))

    const restarted = open(sql)
    expect(restarted.engine.currentState.ordered).toBeUndefined()
    expect(pageInbox(restarted.engine.rows, { limit: 200 }).entries).toEqual([])
    expect(() => restarted.run(USER, "inbox.reindex", { conversations: [conv(1)], done: true }, "user-reindex")).toThrow(/forbidden/)

    const keys = restarted.engine.rows.scan(TABLE_ENTRY).map((r) => r.key)
    const batches = inboxReindexBatches(keys)
    expect(batches).toHaveLength(3)
    expect(batches.map((b) => b.params.done)).toEqual([false, false, true])
    for (const b of batches) restarted.run(SYSTEM, "inbox.reindex", b.params, b.key)
    // A repeated migration replays from the ledger.
    for (const b of batches) restarted.run(SYSTEM, "inbox.reindex", b.params, b.key)
    expect(restarted.engine.currentState.ordered).toBe(true)
    const pages = allPages(restarted.engine.rows)
    expect(pages).toHaveLength(450)
    expect(pages[0]).toBe(conv(449))
  })

  it("a batch with an id that is not valid skips that id and still records done, so the migration ends", () => {
    const sql = store()
    const legacy = open(sql)
    legacy.run(SYSTEM, "inbox.bump", bump(conv(1), 1, 1), "bump:1:1")
    makeLegacy(sql)
    const restarted = open(sql)
    restarted.run(SYSTEM, "inbox.reindex", { conversations: [conv(1), "x".repeat(200), 7], done: true }, "reindex-mixed")
    expect(restarted.engine.currentState.ordered).toBe(true)
    expect(pageInbox(restarted.engine.rows, { limit: 10 }).entries.map((e) => e.conversation)).toEqual([conv(1)])
    expect(() => restarted.run(SYSTEM, "inbox.reindex", { conversations: "nope", done: true }, "reindex-bad")).toThrow(/invalid_params/)
  })

  it("repairs a legacy peer row that points at a DM the user left", () => {
    const sql = store()
    const legacy = open(sql)
    const dm = (conversation: string, rev: number, extra: Partial<InboxBumpParams> = {}) => bump(conversation, rev, rev, { kind: "dm", dm_peer: "user_bob", ...extra })
    legacy.run(SYSTEM, "inbox.bump", dm("conv_dm_FIRST", 1), "a1")
    legacy.run(SYSTEM, "inbox.bump", dm("conv_dm_SECOND", 1), "b1")
    legacy.run(SYSTEM, "inbox.bump", dm("conv_dm_FIRST", 2, { removed: true }), "a2")
    // The code before this change kept the first DM in the peer index for ever.
    sql.exec(`INSERT OR IGNORE INTO inbox_rows (tbl, k, n, json) VALUES (?, ?, NULL, ?)`, TABLE_PEER, "user_bob", JSON.stringify({ conversation: "conv_dm_FIRST" }))
    makeLegacy(sql)
    const restarted = open(sql)
    expect(dmPeer(restarted.engine.rows, "user_bob")).toBe("conv_dm_FIRST")
    // The left DM sorts first by key, so it lands in an earlier batch than the live DM.
    const batches = inboxReindexBatches(restarted.engine.rows.scan(TABLE_ENTRY).map((r) => r.key), 1)
    for (const b of batches) restarted.run(SYSTEM, "inbox.reindex", b.params, b.key)
    expect(dmPeer(restarted.engine.rows, "user_bob")).toBe("conv_dm_SECOND")
  })

  it("a stale or duplicate bump on a legacy entry stays a no-op (no event); the reindex adds its order row", () => {
    const sql = store()
    const legacy = open(sql)
    legacy.run(SYSTEM, "inbox.bump", bump(conv(1), 2, 2), "bump:1:2")
    makeLegacy(sql)
    const restarted = open(sql)
    const before = eventCount(sql)
    restarted.run(SYSTEM, "inbox.bump", bump(conv(1), 1, 1), "bump:1:1")
    restarted.run(USER, "inbox.archive", { conversation: conv(1), archived: false }, "unarchive-noop")
    expect(eventCount(sql)).toBe(before)
  })

  it("batch keys name their contents, so a shifted batch never replays an older one", () => {
    const a = inboxReindexBatches([conv(1), conv(2), conv(3)], 2)
    const b = inboxReindexBatches([conv(0), conv(1), conv(2), conv(3)], 2)
    expect(new Set([...a, ...b].map((x) => x.key)).size).toBe(4)
  })
})

describe("inbox dm_peer index", () => {
  it("a DM the user left releases its peer; the next live DM with that peer takes it", () => {
    const { engine, run } = open()
    const dm = (conversation: string, rev: number, extra: Partial<InboxBumpParams> = {}) => bump(conversation, rev, rev, { kind: "dm", dm_peer: "user_bob", ...extra })
    run(SYSTEM, "inbox.bump", dm("conv_dm_FIRST", 1), "a1")
    run(SYSTEM, "inbox.bump", dm("conv_dm_SECOND", 1), "b1")
    expect(dmPeer(engine.rows, "user_bob")).toBe("conv_dm_FIRST")
    run(SYSTEM, "inbox.bump", dm("conv_dm_FIRST", 2, { removed: true }), "a2")
    expect(dmPeer(engine.rows, "user_bob")).toBeNull()
    run(SYSTEM, "inbox.bump", dm("conv_dm_SECOND", 2), "b2")
    expect(dmPeer(engine.rows, "user_bob")).toBe("conv_dm_SECOND")
    // An older bump of the left DM cannot take the index back.
    run(SYSTEM, "inbox.bump", dm("conv_dm_FIRST", 1), "a1-again")
    expect(dmPeer(engine.rows, "user_bob")).toBe("conv_dm_SECOND")
  })
})
