import { describe, expect, it } from "vitest"
import { inboxViewFor, membersPage } from "../src/conversation/index.ts"
import type { ConversationHead } from "../src/conversation/types.ts"
import type { OutboxItem } from "../src/conversation/engine-types.ts"
import { Group } from "./support/group.ts"

/**
 * A group of any size costs the same per message (plans/cmux-next/home-dm-group-chats/DESIGN.md
 * sections 3 and 6). Past the inline size the member list and read cursors live in rows, the head
 * keeps a bounded roster, a message bumps only its sender and the people it mentions, and every
 * other member pulls its row (unread included) from the conversation when it lists its inbox.
 *
 * The load: one owner and 5,000 simulated members, compared with the same group at 300.
 */
const OWNER = "user_owner"
const member = (n: number) => `user_m${n}`

const grow = (group: Group, from: number, to: number) => {
  for (let n = from; n < to; n++) {
    const code = group.add(OWNER, member(n))
    if (code !== "ok") throw new Error(`adding member ${n}: ${code}`)
  }
}

const bumps = (items: ReadonlyArray<OutboxItem>) => items.filter((item) => item.kind === "inbox.bump")
const bumpFor = (items: ReadonlyArray<OutboxItem>, user: string) => bumps(items).find((item) => (item.payload as { user: string }).user === user)?.payload as
  | { unread?: number; mentions?: number; removed?: boolean }
  | undefined

/** What one plain message (no mentions) costs: outbox items, bumps, row reads, head bytes. */
const costOfOneMessage = (group: Group, sender: string) => {
  const rows = group.host.rows
  const get = rows.get.bind(rows)
  const range = rows.range.bind(rows)
  let reads = 0
  rows.get = ((table: string, key: string) => (reads++, get(table, key))) as typeof rows.get
  rows.range = ((table, q) => (reads++, range(table, q))) as typeof rows.range
  const items = group.outboxOf(() => expect(group.send(sender, "plain message").ok).toBe(true))
  rows.get = get
  rows.range = range
  return { items: items.length, bumps: bumps(items).length, reads, bytes: group.stateBytes }
}

describe("a group of any size", () => {
  const small = new Group(OWNER, [member(0)])
  grow(small, 1, 300)
  const big = new Group(OWNER, [member(0)])
  grow(big, 1, 5000)

  it("holds 5,000 members", () => {
    const page = membersPage(big.host.state as ConversationHead, big.host.rows, { limit: 100 })
    expect(page.member_count).toBe(5001)
    expect(page.members).toHaveLength(100)
    let seen = page.members.length
    let after = page.next
    while (after !== undefined) {
      const next = membersPage(big.host.state as ConversationHead, big.host.rows, { after, limit: 1000 })
      seen += next.members.length
      after = next.next
    }
    expect(seen).toBe(5001)
  })

  it("one message costs the same at 5,000 members as at 300", () => {
    const a = costOfOneMessage(small, member(7))
    const b = costOfOneMessage(big, member(7))
    expect(b.items).toBe(a.items)
    expect(b.bumps).toBe(a.bumps)
    expect(b.bumps).toBeLessThanOrEqual(1)
    expect(b.reads).toBe(a.reads)
    // The head is bounded: a roster, never the whole member list or every read cursor.
    expect(b.bytes).toBeLessThan(64 * 1024)
    expect(b.bytes).toBeLessThan(a.bytes * 1.1)
  })

  it("a mention bumps the person it names, and nobody else", () => {
    const items = big.outboxOf(() => expect(big.send(member(10), "look", [member(4321)]).ok).toBe(true))
    const bump = bumpFor(items, member(4321))
    expect(bump?.mentions).toBeGreaterThanOrEqual(1)
    expect(bumpFor(items, member(4322))).toBeUndefined()
    expect(bumps(items).length).toBeLessThanOrEqual(2)
  })

  it("every other member pulls its unread count from the conversation", () => {
    const quiet = member(4999)
    const before = inboxViewFor(big.host.state as ConversationHead, big.host.rows, quiet)
    expect(before).not.toBeNull()
    expect(big.send(member(11), "one").ok).toBe(true)
    expect(big.send(member(12), "two").ok).toBe(true)
    const after = inboxViewFor(big.host.state as ConversationHead, big.host.rows, quiet)!
    expect(after.unread).toBe(before!.unread + 2)
    expect(after.mentions).toBe(0)
    expect(after.title).toBe("Trip")
    expect(after.preview).toContain("two")
    const mentioned = inboxViewFor(big.host.state as ConversationHead, big.host.rows, member(4321))!
    expect(mentioned.mentions).toBe(1)
  })

  it("reading moves one cursor row and keeps the head the same size", () => {
    const reader = member(4998)
    const bytes = big.stateBytes
    const head = big.host.state as ConversationHead
    expect(big.code(reader, "read_cursor.set", { seq: head.last_seq })).toBe("ok")
    expect(inboxViewFor(big.host.state as ConversationHead, big.host.rows, reader)?.unread).toBe(0)
    expect(big.stateBytes).toBeLessThan(bytes * 1.05)
  })

  it("a removed member deep in the list loses access and is told", () => {
    const gone = member(4000)
    const items = big.outboxOf(() => expect(big.code(OWNER, "participants.remove", { participant: gone })).toBe("ok"))
    expect(bumpFor(items, gone)?.removed).toBe(true)
    expect(big.send(gone, "hello?")).toMatchObject({ ok: false, code: "not_participant" })
    expect(inboxViewFor(big.host.state as ConversationHead, big.host.rows, gone)).toBeNull()
    expect(membersPage(big.host.state as ConversationHead, big.host.rows, { limit: 1 }).member_count).toBe(5000)
  })

  it("roles hold deep in the list: a read-only member cannot post", () => {
    expect(big.code(OWNER, "participants.set_role", { participant: member(3000), role: "read_only" })).toBe("ok")
    expect(big.send(member(3000), "hi")).toMatchObject({ ok: false, code: "read_only" })
    expect(big.code(OWNER, "participants.set_role", { participant: member(3001), role: "admin" })).toBe("ok")
    expect(big.code(member(3001), "participants.remove", { participant: member(3002) })).toBe("ok")
  })

  it("adding the 5,002nd member costs the same as adding the 301st", () => {
    const a = small.outboxOf(() => expect(small.add(OWNER, "user_extra")).toBe("ok"))
    const b = big.outboxOf(() => expect(big.add(OWNER, "user_extra")).toBe("ok"))
    expect(b.length).toBe(a.length)
  })
})
