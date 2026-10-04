import { describe, expect, it } from "vitest"
import {
  makeConversationDomain,
  nextSweepAt,
  RETENTION_BATCH,
  SWEEP_OP,
  TABLE_INV,
  TABLE_MSG,
  TABLE_MSGKEY,
  type ConversationParams,
  type ConversationState,
  type InboxBump,
  type Invite,
  type Message,
  type ParticipantPolicy,
  type Principal
} from "../src/conversation/index.ts"
import { TABLE_UNREAD } from "../src/conversation/domain.ts"
import type { UnreadCounts } from "../src/conversation/fanout.ts"
import { DomainHost, human, text } from "./support/harness.ts"
import { ADDRESS, ALICE, BOB, INV, inviteOp } from "./support/cloud.ts"

/**
 * Owner hygiene (home-messaging.md section 10): the ConversationDO alarm runs the system op
 * `conversation.sweep`, which deletes expired message rows in batches (team retention) and
 * expires pending invites past their 14 days, in one commit with the projection rows.
 */
const DAY = 24 * 3600_000
const session = (user: string, name: string): Principal => ({ identity: `${user}:s`, user, kind: "session", display_name: name })
const SYSTEM: Principal = { identity: "system:conv", kind: "system" }
const allowBob: ParticipantPolicy = (principal, participant) =>
  participant.id === principal.user || participant.id === BOB || participant.kind === "address" ? { ok: true, display_name: participant.display_name } : { ok: false, code: "forbidden" }
const domain = makeConversationDomain({ participantPolicy: allowBob })

const group = (retention?: number) => {
  const host = new DomainHost<ConversationState, ConversationParams>(domain)
  const created = host.run(
    session(ALICE, "Alice"),
    "conversation.create",
    { id: "conv_GROUP", kind: "group", title: "Team", participants: [human(ALICE, "Alice"), human(BOB, "Bob")], ...(retention ? { retention_days: retention } : {}) },
    "create"
  )
  expect(created.ok).toBe(true)
  host.outbox.length = 0
  return host
}
const send = (host: DomainHost<ConversationState, ConversationParams>, key: string, who = ALICE, body = key) =>
  expect(host.run(session(who, who === ALICE ? "Alice" : "Bob"), "message.send", { client_msg_id: key, parts: [text(body)] }, key)).toMatchObject({ ok: true })
const messages = (host: DomainHost<ConversationState, ConversationParams>) =>
  host.rows.all<Message>(TABLE_MSG).sort((a, b) => a.seq - b.seq)
const oldest = (host: DomainHost<ConversationState, ConversationParams>) => messages(host)[0] ?? null
const sweep = (host: DomainHost<ConversationState, ConversationParams>) => host.run(SYSTEM, SWEEP_OP, {}, `sweep:${host.state!.rev}:${host.now}`)

describe("conversation.sweep: retention", () => {
  it("deletes the expired messages, their client-id keys, and projects one delete_through row", () => {
    const host = group(30)
    for (const key of ["m1", "m2", "m3"]) send(host, key)
    host.now += 31 * DAY
    send(host, "m4")
    const before = host.state!
    host.outbox.length = 0
    const r = sweep(host)
    expect(r).toMatchObject({ ok: true, value: { retention: { through_seq: 3, deleted: 3 } } })
    expect(messages(host).map((m) => m.client_msg_id)).toEqual(["m4"])
    expect(host.rows.all(TABLE_MSGKEY)).toHaveLength(1)
    // One commit: rev moves by one, the message order and list order stay.
    expect(host.state!.rev).toBe(before.rev + 1)
    expect(host.state!.last_seq).toBe(before.last_seq)
    expect(host.state!.updated_at).toBe(before.updated_at)
    const projections = host.outbox.filter((item) => !item.target)
    expect(projections.filter((item) => item.kind === "home.message.delete_through")).toEqual([
      { kind: "home.message.delete_through", entity: "conv_GROUP:through", payload: { conversation_id: "conv_GROUP", seq: 3 } }
    ])
    expect(projections.some((item) => item.kind === "home.message.delete")).toBe(false)
    // The newest message survived, so the preview stays; only Bob, who had not read m1..m3, gets lower counts.
    const bumps = host.outbox.filter((item) => item.kind === "inbox.bump").map((item) => item.payload as InboxBump)
    expect(bumps.map((b) => [b.user, b.unread, b.preview])).toEqual([[BOB, 1, "Alice: m4"]])
  })

  it("a sweep with nothing due commits nothing", () => {
    const host = group(30)
    send(host, "m1")
    host.now += 29 * DAY
    host.outbox.length = 0
    const rev = host.state!.rev
    expect(sweep(host)).toMatchObject({ ok: true, changed: false })
    expect(host.state!.rev).toBe(rev)
    expect(messages(host)).toHaveLength(1)
    expect(host.outbox).toEqual([])
  })

  it("keeps everything without a retention policy (default keep)", () => {
    const host = group()
    send(host, "m1")
    host.now += 3650 * DAY
    expect(sweep(host)).toMatchObject({ ok: true, changed: false })
    expect(messages(host)).toHaveLength(1)
    expect(nextSweepAt(host.state, oldest(host))).toBeNull()
  })

  it("deletes at most RETENTION_BATCH rows per commit; the next wake is due at once while more remain", () => {
    const host = group(30)
    for (let i = 0; i < RETENTION_BATCH + 3; i++) send(host, `m${i}`, i % 2 === 0 ? ALICE : BOB)
    host.now += 31 * DAY
    expect(sweep(host)).toMatchObject({ ok: true, value: { retention: { through_seq: RETENTION_BATCH, deleted: RETENTION_BATCH } } })
    expect(messages(host)).toHaveLength(3)
    expect(nextSweepAt(host.state, oldest(host))).toBeLessThanOrEqual(host.now)
    expect(sweep(host)).toMatchObject({ ok: true, value: { retention: { through_seq: RETENTION_BATCH + 3, deleted: 3 } } })
    expect(messages(host)).toEqual([])
    expect(nextSweepAt(host.state, oldest(host))).toBeNull()
  })

  it("when the newest message expires, every current human's inbox preview is cleared", () => {
    const host = group(30)
    send(host, "m1", ALICE, "secret plan")
    host.now += 31 * DAY
    host.outbox.length = 0
    expect(sweep(host)).toMatchObject({ ok: true })
    const bumps = host.outbox.filter((item) => item.kind === "inbox.bump").map((item) => item.payload as InboxBump)
    expect(bumps.map((b) => b.user).sort()).toEqual([ALICE, BOB].sort())
    for (const bump of bumps) {
      expect(bump.preview).toBe("")
      expect(bump.rev).toBe(host.state!.rev)
      expect(bump.last_seq).toBe(1)
    }
    expect(JSON.stringify(host.outbox)).not.toContain("secret plan")
  })

  it("expired messages a human had not read leave that human's stored counts and inbox", () => {
    const host = group(30)
    send(host, "m1", ALICE, "old")
    host.now += 31 * DAY
    send(host, "m2", ALICE, "new")
    expect(host.rows.get<UnreadCounts>(TABLE_UNREAD, BOB)?.row).toEqual({ unread: 2, mentions: 0 })
    host.outbox.length = 0
    expect(sweep(host)).toMatchObject({ ok: true, value: { retention: { through_seq: 1, deleted: 1 } } })
    expect(host.rows.get<UnreadCounts>(TABLE_UNREAD, BOB)?.row).toEqual({ unread: 1, mentions: 0 })
    const bumps = host.outbox.filter((item) => item.kind === "inbox.bump").map((item) => item.payload as InboxBump)
    // Alice wrote both messages, so only Bob's counts drop; the newest message stays the preview.
    expect(bumps).toHaveLength(1)
    expect(bumps[0]).toMatchObject({ user: BOB, unread: 1, mentions: 0, rev: host.state!.rev, preview: "Alice: new" })
  })

  it("only the owner itself runs it: a participant is refused", () => {
    const host = group(30)
    send(host, "m1")
    host.now += 31 * DAY
    expect(host.run(session(ALICE, "Alice"), SWEEP_OP, {}, "sweep-by-alice")).toMatchObject({ ok: false, code: "forbidden" })
    expect(messages(host)).toHaveLength(1)
  })

  it("the next sweep is the oldest message's expiry", () => {
    const host = group(30)
    send(host, "m1")
    const created = Date.parse(oldest(host)!.created_at)
    expect(nextSweepAt(host.state, oldest(host))).toBe(created + 30 * DAY)
    expect(nextSweepAt(null, null)).toBeNull()
  })
})

describe("conversation.sweep: invite expiry", () => {
  const invited = () => {
    const host = group()
    const { kind: _kind, ...params } = inviteOp()
    expect(host.run(session(ALICE, "Alice"), "invite.create", params, "inv")).toMatchObject({ ok: true })
    host.outbox.length = 0
    return host
  }

  it("is due at the open invite's expiry", () => {
    const host = invited()
    const invite = host.state!.invites!.find((i) => i.id === INV)!
    expect(nextSweepAt(host.state, oldest(host))).toBe(Date.parse(invite.expires_at))
  })

  it("expires a pending invite after 14 days, releases its address and projects both", () => {
    const host = invited()
    host.now += 13 * DAY
    expect(sweep(host)).toMatchObject({ ok: true, changed: false })
    host.now += 2 * DAY
    expect(sweep(host)).toMatchObject({ ok: true, value: { invites_expired: 1 } })
    expect(host.state!.invites).toEqual([])
    expect(host.rows.all<Invite>(TABLE_INV).find((i) => i.id === INV)).toMatchObject({ status: "expired" })
    // In a group the released address is dropped from the head.
    expect(host.state!.participants.some((p) => p.id === ADDRESS)).toBe(false)
    expect(host.outbox).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "home.invite.upsert", entity: INV, payload: expect.objectContaining({ status: "expired" }) }),
        expect.objectContaining({ kind: "home.participant.upsert", entity: `conv_GROUP:${ADDRESS}` })
      ])
    )
    expect(nextSweepAt(host.state, oldest(host))).toBeNull()
  })
})
