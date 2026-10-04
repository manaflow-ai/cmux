import { describe, expect, it } from "vitest"
import type { Principal } from "../src/conversation/engine-types.ts"
import {
  bumpEntry,
  emptyInbox,
  inboxDomain,
  isMuted,
  listInbox,
  reduceInbox,
  TABLE_ENTRY,
  type InboxBumpParams,
  type InboxEntry,
  type InboxRecord
} from "../src/inbox/index.ts"
import { DomainHost, Rng } from "./support/harness.ts"

const SYSTEM: Principal = { identity: "system:conv", kind: "system" }
const USER: Principal = { identity: "user_alice", user: "user_alice", kind: "session" }
const NOW = Date.UTC(2026, 9, 1, 12)

const bump = (conversation: string, rev: number, last_seq: number, extra: Partial<InboxBumpParams> = {}): InboxBumpParams => ({
  conversation,
  rev,
  kind: "group",
  title: `t${rev}`,
  last_seq,
  last_at: `2026-10-01T12:00:${String(last_seq % 60).padStart(2, "0")}.000Z`,
  preview: `p${rev}`,
  ...extra
})

const ok = (result: ReturnType<typeof reduceInbox>): InboxRecord => {
  if (!result.ok) throw new Error(result.code)
  return result.value
}

describe("inbox bump", () => {
  it("applies only a newer rev; duplicates and stale bumps change nothing", () => {
    let inbox = ok(reduceInbox(emptyInbox(), "inbox.bump", bump("conv_a", 2, 2, { unread: 2, mentions: 0 }), NOW))
    const entry = inbox.entries.conv_a!
    expect(bumpEntry(entry, bump("conv_a", 2, 2, { unread: 2, mentions: 0 }))).toBe(entry)
    expect(bumpEntry(entry, bump("conv_a", 1, 1, { unread: 1, mentions: 0 }))).toBe(entry)
    inbox = ok(reduceInbox(inbox, "inbox.bump", bump("conv_a", 3, 3), NOW))
    // A bump without counts keeps the counts of the newest bump that had them.
    expect(inbox.entries.conv_a).toMatchObject({ rev: 3, title: "t3", unread: 2, counts_rev: 2 })
  })

  it("un-archives when last_seq grows past the archive point", () => {
    let inbox = ok(reduceInbox(emptyInbox(), "inbox.bump", bump("conv_a", 1, 1), NOW))
    inbox = ok(reduceInbox(inbox, "inbox.archive", { conversation: "conv_a", archived: true }, NOW))
    inbox = ok(reduceInbox(inbox, "inbox.bump", bump("conv_a", 2, 1), NOW))
    expect(inbox.entries.conv_a!.archived).toBe(true)
    inbox = ok(reduceInbox(inbox, "inbox.bump", bump("conv_a", 3, 2), NOW))
    expect(inbox.entries.conv_a!.archived).toBe(false)
  })

  it("keeps a removed entry as a tombstone that older bumps cannot resurrect", () => {
    let inbox = ok(reduceInbox(emptyInbox(), "inbox.bump", bump("conv_a", 5, 5, { removed: true }), NOW))
    inbox = ok(reduceInbox(inbox, "inbox.bump", bump("conv_a", 4, 4), NOW))
    expect(inbox.entries.conv_a!.removed).toBe(true)
    expect(listInbox(Object.values(inbox.entries), { limit: 10 })).toEqual([])
    expect(reduceInbox(inbox, "inbox.pin", { conversation: "conv_a", pinned: true }, NOW)).toEqual({ ok: false, code: "unknown_conversation" })
  })

  it("is order independent: shuffled, duplicated bumps equal the in-order result", () => {
    for (let seed = 1; seed <= 300; seed++) {
      const rng = new Rng(BigInt(seed))
      const bumps: Array<InboxBumpParams> = []
      for (const conversation of ["conv_a", "conv_b", "conv_c"]) {
        let lastSeq = 0
        const revs = 1 + rng.below(12)
        for (let rev = 1; rev <= revs; rev++) {
          lastSeq += rng.below(3)
          const counts = rng.below(2) === 0 ? { unread: rng.below(9), mentions: rng.below(3) } : {}
          bumps.push(bump(conversation, rev, lastSeq, { ...counts, ...(rng.below(10) === 0 ? { removed: true } : {}) }))
        }
      }
      const start = emptyInbox()
      const inOrder = bumps.reduce((inbox, b) => ok(reduceInbox(inbox, "inbox.bump", b, NOW)), start)
      const shuffled = [...bumps, ...bumps.filter(() => rng.below(3) === 0)]
      for (let i = shuffled.length - 1; i > 0; i--) {
        const j = rng.below(i + 1)
        ;[shuffled[i], shuffled[j]] = [shuffled[j]!, shuffled[i]!]
      }
      const outOfOrder = shuffled.reduce((inbox, b) => ok(reduceInbox(inbox, "inbox.bump", b, NOW)), start)
      expect(outOfOrder, `seed ${seed}`).toEqual(inOrder)
    }
  })

  it("is order independent after an archive", () => {
    for (let seed = 1; seed <= 100; seed++) {
      const rng = new Rng(BigInt(seed + 500))
      let base = ok(reduceInbox(emptyInbox(), "inbox.bump", bump("conv_a", 1, 3), NOW))
      base = ok(reduceInbox(base, "inbox.archive", { conversation: "conv_a", archived: true }, NOW))
      const bumps = Array.from({ length: 6 }, (_, i) => bump("conv_a", i + 2, 3 + (rng.below(2) === 0 ? 0 : i)))
      const inOrder = bumps.reduce((inbox, b) => ok(reduceInbox(inbox, "inbox.bump", b, NOW)), base)
      const reversed = [...bumps].reverse().reduce((inbox, b) => ok(reduceInbox(inbox, "inbox.bump", b, NOW)), base)
      expect(reversed, `seed ${seed}`).toEqual(inOrder)
    }
  })
})

describe("inbox user ops and list", () => {
  const seeded = (): InboxRecord => {
    let inbox = emptyInbox()
    for (const [conversation, seq] of [
      ["conv_a", 10],
      ["conv_b", 30],
      ["conv_c", 20],
      ["conv_d", 40]
    ] as const) {
      inbox = ok(reduceInbox(inbox, "inbox.bump", bump(conversation, 1, seq), NOW))
    }
    return inbox
  }

  it("orders pinned by position, then last_at newest first", () => {
    let inbox = seeded()
    inbox = ok(reduceInbox(inbox, "inbox.pin", { conversation: "conv_a", pinned: true }, NOW))
    inbox = ok(reduceInbox(inbox, "inbox.pin", { conversation: "conv_c", pinned: true, position: 0 }, NOW))
    inbox = ok(reduceInbox(inbox, "inbox.pin", { conversation: "conv_b", pinned: true }, NOW))
    expect(inbox.entries.conv_b!.pin_position).toBe(1)
    expect(listInbox(Object.values(inbox.entries), { limit: 10 }).map((e) => e.conversation)).toEqual(["conv_a", "conv_c", "conv_b", "conv_d"])
    inbox = ok(reduceInbox(inbox, "inbox.pin", { conversation: "conv_a", pinned: false }, NOW))
    inbox = ok(reduceInbox(inbox, "inbox.archive", { conversation: "conv_d", archived: true }, NOW))
    expect(listInbox(Object.values(inbox.entries), { limit: 10 }).map((e) => e.conversation)).toEqual(["conv_c", "conv_b", "conv_a"])
    expect(listInbox(Object.values(inbox.entries), { limit: 10, include_archived: true }).map((e) => e.conversation)).toEqual([
      "conv_c",
      "conv_b",
      "conv_d",
      "conv_a"
    ])
    expect(listInbox(Object.values(inbox.entries), { limit: 1 })).toHaveLength(1)
  })

  it("mute with and without an end, mark unread, and validation", () => {
    let inbox = seeded()
    inbox = ok(reduceInbox(inbox, "inbox.mute", { conversation: "conv_a", muted: true, until: NOW + 1000 }, NOW))
    const entry: InboxEntry = inbox.entries.conv_a!
    expect([isMuted(entry, NOW), isMuted(entry, NOW + 1000)]).toEqual([true, false])
    inbox = ok(reduceInbox(inbox, "inbox.mute", { conversation: "conv_b", muted: true }, NOW))
    expect(isMuted(inbox.entries.conv_b!, NOW + 10 ** 12)).toBe(true)
    inbox = ok(reduceInbox(inbox, "inbox.mute", { conversation: "conv_b", muted: false }, NOW))
    expect(isMuted(inbox.entries.conv_b!, NOW)).toBe(false)
    expect(reduceInbox(inbox, "inbox.mute", { conversation: "conv_a", muted: true, until: NOW }, NOW)).toEqual({ ok: false, code: "invalid_params" })
    inbox = ok(reduceInbox(inbox, "inbox.mark_unread", { conversation: "conv_a", unread: true }, NOW))
    expect(inbox.entries.conv_a!.marked_unread).toBe(true)
    expect(reduceInbox(inbox, "inbox.archive", { conversation: "conv_zzz", archived: true }, NOW)).toEqual({ ok: false, code: "unknown_conversation" })
    expect(reduceInbox(inbox, "inbox.bump", { conversation: "conv_a" }, NOW)).toEqual({ ok: false, code: "invalid_params" })
  })
})

describe("inbox Domain (rows)", () => {
  it("stores entries as rows, refuses bumps from users, and no-ops stale bumps", () => {
    const host = new DomainHost(inboxDomain)
    host.now = NOW
    const asParams = (b: InboxBumpParams) => ({ ...b, user: "user_alice" })
    expect(host.run(USER, "inbox.bump", asParams(bump("conv_a", 1, 1)), "b0")).toMatchObject({ ok: false, code: "forbidden" })
    // An unbound inbox refuses user ops until its first bump names the owner.
    expect(host.run(USER, "inbox.pin", { conversation: "conv_a", pinned: true }, "early")).toMatchObject({ ok: false, code: "forbidden" })
    expect(host.run(SYSTEM, "inbox.bump", asParams(bump("conv_a", 2, 2)), "bump:conv_a:2")).toMatchObject({ ok: true })
    expect(host.run(SYSTEM, "inbox.bump", asParams(bump("conv_a", 1, 1)), "bump:conv_a:1")).toMatchObject({ ok: true, changed: false })
    expect(host.run(SYSTEM, "inbox.pin", { conversation: "conv_a", pinned: true }, "p0")).toMatchObject({ ok: false, code: "forbidden" })
    expect(host.run(USER, "inbox.pin", { conversation: "conv_a", pinned: true }, "p1")).toMatchObject({ ok: true })
    expect(host.state).toEqual({ user: "user_alice", next_pin: 1 })
    // Nothing changes: no event.
    expect(host.run(USER, "inbox.pin", { conversation: "conv_a", pinned: true }, "p2")).toMatchObject({ ok: true, changed: false })
    const MALLORY: Principal = { identity: "user_mallory", user: "user_mallory", kind: "session" }
    expect(host.run(MALLORY, "inbox.archive", { conversation: "conv_a", archived: true }, "x")).toMatchObject({ ok: false, code: "forbidden" })
    expect(host.run(SYSTEM, "inbox.bump", { ...bump("conv_b", 1, 1), user: "user_mallory" }, "bump:conv_b:1")).toMatchObject({ ok: false, code: "forbidden" })
    const rows = host.rows.all<InboxEntry>(TABLE_ENTRY)
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ conversation: "conv_a", rev: 2, pinned: true, pin_position: 0 })
    expect(listInbox(rows, { limit: 200 })[0]?.conversation).toBe("conv_a")
  })
})

describe("inbox totals (home-scale review P1)", () => {
  it("the inbox head keeps unread, mention and unread-conversation totals across bumps", async () => {
    const { inboxDomain } = await import("../src/inbox/domain.ts")
    const { MemoryRows } = await import("@cmux/ownership")
    const rows = new MemoryRows()
    const system = { identity: "system:test", kind: "system" as const }
    let head = inboxDomain.initial()
    const bump = (conversation: string, rev: number, unread: number, mentions: number) => {
      const r = inboxDomain.reduce(head, "inbox.bump", { user: "user_a", conversation, rev, kind: "group", title: "", last_seq: rev, last_at: "2026-10-02T00:00:00.000Z", preview: "", unread, mentions }, { principal: system, now: 1, tx: `t${conversation}${rev}`, newId: (p: string) => `${p}1`, rows })
      if (!r.ok) throw new Error(r.code)
      rows.apply(r.writes ?? [])
      head = r.state
    }
    bump("conv_A", 1, 2, 1)
    bump("conv_B", 1, 3, 0)
    expect(head).toMatchObject({ totals: { unread: 5, mentions: 1, conversations: 2 } })
    bump("conv_A", 2, 0, 0)
    expect(head).toMatchObject({ totals: { unread: 3, mentions: 0, conversations: 1 } })
    // A stale bump changes nothing.
    bump("conv_A", 1, 9, 9)
    expect(head).toMatchObject({ totals: { unread: 3, mentions: 0, conversations: 1 } })
  })
})
