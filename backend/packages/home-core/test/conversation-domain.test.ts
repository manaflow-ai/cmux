import { describe, expect, it } from "vitest"
import {
  conversationDomain,
  dmConversationId,
  fanOut,
  makeConversationDomain,
  type ParticipantPolicy,
  PREVIEW_CHARS,
  previewOf,
  SEARCH_BODY_BYTES,
  TABLE_INV,
  TABLE_MSG,
  type ConversationParams,
  type ConversationState,
  type Invite,
  type Message,
  type OutboxItem,
  type Principal
} from "../src/conversation/index.ts"
import { fanOutItems } from "../src/conversation/outbox.ts"
import { utf8Bytes } from "../src/conversation/validate.ts"
import { agent, CoreHost, DomainHost, human, text } from "./support/harness.ts"
import { ALICE, BOB, CAROL, CHIEF, ADDRESS, groupHead, INV, inviteOp, tokenHash } from "./support/cloud.ts"

const session = (user: string, name: string): Principal => ({ identity: `${user}:s`, user, kind: "session", display_name: name })
const SYSTEM: Principal = { identity: "system:test", kind: "system" }
const CHIEF_P: Principal = { identity: `${CHIEF}:t`, agent: CHIEF, user: ALICE, kind: "agent" }

/** A reach policy as the DO would inject: a directory of names and chief owners; strangers refused. */
const DIRECTORY: Record<string, { name: string; owner?: string }> = {
  [ALICE]: { name: "Alice" },
  [BOB]: { name: "Bob" },
  [CAROL]: { name: "Carol" },
  [CHIEF]: { name: "Chief", owner: ALICE }
}
const testPolicy: ParticipantPolicy = (principal, participant) => {
  if (participant.kind === "address") return { ok: true, display_name: participant.display_name }
  const entry = DIRECTORY[participant.id]
  if (!entry) return { ok: false, code: "forbidden" }
  if (entry.owner && entry.owner !== principal.user) return { ok: false, code: "forbidden" }
  return { ok: true, display_name: entry.name, ...(entry.owner ? { owner_user: entry.owner } : {}) }
}
const testDomain = makeConversationDomain({
  participantPolicy: testPolicy,
  addressIdsFor: (principal) => (principal.email === "carol@example.com" ? [ADDRESS] : [])
})

const newGroup = (domain = testDomain) => {
  const host = new DomainHost<ConversationState, ConversationParams>(domain)
  const created = host.run(
    session(ALICE, "Alice"),
    "conversation.create",
    { id: "conv_GROUP", kind: "group", title: "Team", participants: [human(ALICE, "Alice"), human(BOB, "Bob"), agent(CHIEF, ALICE)] },
    "create-1"
  )
  expect(created.ok).toBe(true)
  host.outbox.length = 0
  return host
}

const kinds = (items: ReadonlyArray<OutboxItem>) => items.map((item) => `${item.kind}${item.target ? `>${item.target.class}:${item.target.name}` : ""}`)

describe("conversation Domain", () => {
  it("create bumps every human and projects the conversation and participants", () => {
    const host = new DomainHost<ConversationState, ConversationParams>(testDomain)
    const result = host.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_G", kind: "group", title: "T", participants: [human(ALICE), human(BOB)] }, "c")
    expect(result.ok).toBe(true)
    expect(kinds(host.outbox)).toEqual([
      `inbox.bump>UserDO:${ALICE}`,
      `inbox.bump>UserDO:${BOB}`,
      "home.conversation.upsert",
      "home.participant.upsert",
      "home.participant.upsert"
    ])
    expect(host.outbox[0]).toMatchObject({ entity: "bump:conv_G:1", target: { coalesce: "bump:conv_G" }, payload: { rev: 1, unread: 0 } })
    expect(host.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_G", kind: "group", title: "T", participants: [human(ALICE)] }, "c2")).toMatchObject({
      ok: false,
      code: "conversation_exists"
    })
  })

  it("send writes the message row, bumps humans, wakes a mentioned chief and projects the search row", () => {
    const host = newGroup()
    const params = { client_msg_id: "m1", parts: [{ type: "text", text: "@chief go", runs: [{ start: 0, length: 6, mention: CHIEF }] }] }
    const result = host.run(session(BOB, "Bob"), "message.send", params, "m1")
    expect(result).toMatchObject({ ok: true, value: { rev: 2, seq: 1 } })
    const message = host.rows.all<Message>(TABLE_MSG)[0]!
    expect(message).toMatchObject({ author: BOB, seq: 1, client_msg_id: "m1" })
    expect(message.id).toMatch(/^msg_[0-9a-f]{20}$/)
    expect(kinds(host.outbox)).toEqual([
      `inbox.bump>UserDO:${ALICE}`,
      `inbox.bump>UserDO:${BOB}`,
      `mux.wake>MuxDO:${CHIEF}`,
      "home.conversation.upsert",
      "home.message.upsert"
    ])
    expect(host.outbox[0]!.payload).toMatchObject({ preview: "Bob: @chief go", last_seq: 1 })
    expect(host.outbox[2]).toMatchObject({ entity: "wake:conv_GROUP:1", payload: { reason: "mention", seq: 1 } })
    // The same client_msg_id under another key is refused; the params never pick the actor.
    expect(host.run(session(BOB, "Bob"), "message.send", { ...params, actor: ALICE }, "other")).toMatchObject({ ok: false, code: "idempotency_conflict" })
    expect(host.run(CHIEF_P, "message.send", { client_msg_id: "m2", parts: [text("on it")] }, "m2")).toMatchObject({ ok: true })
    expect(host.rows.all<Message>(TABLE_MSG).map((row) => row.author)).toEqual([BOB, CHIEF])
  })

  it("edit and retract load their target from rows; retract deletes the search row", () => {
    const host = newGroup()
    host.run(session(BOB, "Bob"), "message.send", { client_msg_id: "m1", parts: [text("draft")] }, "m1")
    const id = host.rows.all<Message>(TABLE_MSG)[0]!.id
    host.outbox.length = 0
    expect(host.run(session(BOB, "Bob"), "message.edit", { message_id: id, parts: [text("final")] }, "e1")).toMatchObject({ ok: true })
    expect(kinds(host.outbox)).toContain("home.message.upsert")
    host.outbox.length = 0
    expect(host.run(session(ALICE, "Alice"), "message.retract", { message_id: id }, "r0")).toMatchObject({ ok: false, code: "not_author" })
    expect(host.run(session(BOB, "Bob"), "message.retract", { message_id: id }, "r1")).toMatchObject({ ok: true })
    expect(kinds(host.outbox)).toContain("home.message.delete")
    expect(host.rows.all<Message>(TABLE_MSG)[0]!.parts).toEqual([])
  })

  it("a chief conversation is created by the system and wakes the chief on every owner message", () => {
    const host = new DomainHost<ConversationState, ConversationParams>(conversationDomain)
    const params = { id: "conv_CHIEF", kind: "chief", owner: ALICE, title: "Chief", participants: [human(ALICE), agent(CHIEF, ALICE)] }
    expect(host.run(session(ALICE, "Alice"), "conversation.create", params, "c0")).toMatchObject({ ok: false, code: "forbidden" })
    expect(host.run(SYSTEM, "conversation.create", params, "c1")).toMatchObject({ ok: true })
    host.outbox.length = 0
    host.run(session(ALICE, "Alice"), "message.send", { client_msg_id: "m1", parts: [text("hi")] }, "m1")
    expect(host.outbox.find((item) => item.kind === "mux.wake")).toMatchObject({ payload: { reason: "dm" }, target: { name: CHIEF } })
  })

  it("dm.open is idempotent by id and answers only its participants", () => {
    const host = new DomainHost<ConversationState, ConversationParams>(testDomain)
    const params = { id: dmConversationId(ALICE, BOB), participants: [human(ALICE), human(BOB)] }
    expect(host.run(session(ALICE, "Alice"), "dm.open", params, "d1")).toMatchObject({ ok: true })
    expect(host.run(session(BOB, "Bob"), "dm.open", params, "d2")).toMatchObject({ ok: true, changed: false })
    expect(host.run(session(CAROL, "Carol"), "dm.open", params, "d3")).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("invites: delivery item without secrets, accept by proof only, closed invites move to rows", () => {
    const host = newGroup()
    const op = inviteOp()
    const { kind: _kind, ...params } = op
    expect(host.run(session(ALICE, "Alice"), "invite.create", params, "i1")).toMatchObject({ ok: true })
    const deliver = host.outbox.find((item) => item.kind === "address.deliver")
    expect(deliver).toMatchObject({ entity: `deliver:${INV}`, target: { class: "AddressDO", name: ADDRESS } })
    expect(Object.keys(deliver!.payload as object)).toEqual(
      expect.arrayContaining(["invite", "conversation", "address", "channel", "locale", "copy_variant", "invited_by"])
    )
    for (const item of host.outbox) expect(JSON.stringify(item)).not.toContain(op.token_hash)
    // The stored hash cannot accept: the Domain hashes the proof.
    const verifiedCarol = { ...session(CAROL, "Carol"), email: "carol@example.com", email_verified: true }
    expect(host.run(verifiedCarol, "invite.accept", { token_hash: op.token_hash }, "a0")).toMatchObject({ ok: false, code: "unknown_invite" })
    expect(host.run(verifiedCarol, "invite.accept", { proof: op.token_hash }, "a1")).toMatchObject({ ok: false, code: "unknown_invite" })
    expect(host.run(verifiedCarol, "invite.accept", { proof: "secret-1" }, "a2")).toMatchObject({ ok: true })
    expect(host.state?.invites).toEqual([])
    expect(host.state?.participants.find((p) => p.id === CAROL)?.display_name).toBe("Carol")
    expect(host.rows.all<Invite>(TABLE_INV)[0]).toMatchObject({ status: "accepted", accepted_by: CAROL })
    expect(host.run(session("user_dave", "Dave"), "invite.accept", { proof: "secret-1" }, "a3")).toMatchObject({ ok: false, code: "invite_not_pending" })
    // A closed invite lives only in rows; its id and hash still cannot be reused.
    expect(host.run(session(ALICE, "Alice"), "invite.create", params, "i2")).toMatchObject({ ok: false, code: "duplicate_invite" })
    expect(host.run(session(ALICE, "Alice"), "invite.create", { ...params, invite_id: `inv_${"0".repeat(25)}9` }, "i3")).toMatchObject({
      ok: false,
      code: "duplicate_invite"
    })
  })

  it("binding by email needs email_verified; Stack names are cleaned, not refused", () => {
    const { kind: _kind, ...params } = inviteOp()
    const unverified = newGroup()
    unverified.run(session(ALICE, "Alice"), "invite.create", params, "i1")
    const name = `Carol\u0007${"x".repeat(300)}`
    unverified.run({ ...session(CAROL, name), email: "carol@example.com", email_verified: false }, "invite.accept", { proof: "secret-1" }, "a")
    expect(unverified.state?.invites?.[0]).toMatchObject({ status: "pending_approval", requested_by: CAROL })
    expect(unverified.state?.invites?.[0]?.requested_name).toHaveLength(100)
    expect(unverified.state?.invites?.[0]?.requested_name).not.toMatch(/\p{Cc}/u)
    expect(unverified.run(session(ALICE, "Alice"), "invite.approve_join", { invite_id: INV }, "ap")).toMatchObject({ ok: true })
    expect(unverified.state?.participants.some((p) => p.id === CAROL)).toBe(true)
    const blank = newGroup()
    blank.run(session(ALICE, "Alice"), "invite.create", { ...params, channel: "email" }, "i1")
    blank.run({ ...session(CAROL, "\u0000 "), email: "carol@example.com", email_verified: true }, "invite.accept", { proof: "secret-1" }, "a")
    expect(blank.state?.participants.find((p) => p.id === CAROL)?.display_name).toBe("Member")
  })

  it("participant policy: trusted names and owners, strangers and other people's chiefs refused, team from the principal", () => {
    const host = new DomainHost<ConversationState, ConversationParams>(conversationDomain)
    const make = (principal: Principal, participants: Array<unknown>, extra: Record<string, unknown> = {}) =>
      host.run(principal, "conversation.create", { id: "conv_P", kind: "group", title: "T", participants, ...extra }, `c${Math.random()}`)
    // Default policy: no relationship signal for a stranger.
    expect(make(session(ALICE, "Alice"), [human(ALICE), human(BOB)])).toMatchObject({ ok: false, code: "forbidden" })
    expect(make(session(ALICE, "Alice"), [human(ALICE), agent(CHIEF, ALICE)])).toMatchObject({ ok: false, code: "forbidden" })
    expect(make({ ...session(ALICE, "Alice"), team: "team_a" }, [human(ALICE)], { team: "team_b" })).toMatchObject({ ok: false, code: "forbidden" })
    expect(make({ ...session(ALICE, "Alice"), team: "team_a" }, [human(ALICE, "Mallory")], { team: "team_a" })).toMatchObject({ ok: true })
    expect(host.state?.team).toBe("team_a")
    expect(host.state?.participants[0]?.display_name).toBe("Alice")
    const group = newGroup()
    expect(group.run(session(BOB, "Bob"), "participants.add", { participant: agent(CHIEF, BOB) }, "p1")).toMatchObject({ ok: false, code: "forbidden" })
    expect(group.run(session(BOB, "Bob"), "participants.add", { participant: human(CAROL, "Mallory") }, "p2")).toMatchObject({ ok: true })
    expect(group.state?.participants.find((p) => p.id === CAROL)?.display_name).toBe("Carol")
    expect(group.run(session(BOB, "Bob"), "participants.add", { participant: human("user_stranger") }, "p3")).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("client_msg_id is unique per author", () => {
    const host = newGroup()
    expect(host.run(session(ALICE, "Alice"), "message.send", { client_msg_id: "same", parts: [text("a")] }, "same")).toMatchObject({ ok: true })
    expect(host.run(session(BOB, "Bob"), "message.send", { client_msg_id: "same", parts: [text("b")] }, "same")).toMatchObject({ ok: true })
    expect(host.run(session(BOB, "Bob"), "message.send", { client_msg_id: "same", parts: [text("c")] }, "other")).toMatchObject({ ok: false, code: "idempotency_conflict" })
  })
})

describe("fan-out", () => {
  it("counts unread and mentions when the host passes counts, and resets on a full read", () => {
    const host = new CoreHost(groupHead())
    const before = host.head
    const op = { kind: "message.send" as const, client_msg_id: "m1", parts: [{ type: "text" as const, text: "@bob", runs: [{ start: 0, length: 4, mention: BOB }] }] }
    const request = host.request(ALICE, "m1", op)
    const result = host.run(ALICE, "m1", op)
    if (!result.ok) throw new Error(result.code)
    const fan = fanOut({ before, request, commit: result.commit, counts: { [ALICE]: { unread: 0, mentions: 0 }, [BOB]: { unread: 2, mentions: 1 } } })
    expect(fan.bumps.map((b) => [b.user, b.unread, b.mentions])).toEqual([
      [ALICE, 0, 0],
      [BOB, 3, 2]
    ])
    expect(fan.wakes).toEqual([])
    const read = host.request(BOB, "r", { kind: "read_cursor.set", seq: 1 })
    const readResult = host.run(BOB, "r", { kind: "read_cursor.set", seq: 1 })
    if (!readResult.ok) throw new Error(readResult.code)
    expect(fanOut({ before: result.commit.head, request: read, commit: readResult.commit }).bumps).toMatchObject([{ user: BOB, unread: 0, mentions: 0 }])
  })

  it("every bump carries the push facts of the last message and the recipient's join point (UserDO decides push)", () => {
    const host = new CoreHost(groupHead())
    const before = host.head
    const op = { kind: "message.send" as const, client_msg_id: "m1", parts: [{ type: "text" as const, text: "@bob", runs: [{ start: 0, length: 4, mention: BOB }] }] }
    const request = host.request(ALICE, "m1", op)
    const result = host.run(ALICE, "m1", op)
    if (!result.ok) throw new Error(result.code)
    const bumps = fanOut({ before, request, commit: result.commit }).bumps
    expect(bumps.find((b) => b.user === BOB)).toMatchObject({ last_author: ALICE, last_author_kind: "human", last_mention: true, joined_seq: 0 })
    expect(bumps.find((b) => b.user === ALICE)).toMatchObject({ last_author: ALICE, last_author_kind: "human", joined_seq: 0 })
    expect(bumps.find((b) => b.user === ALICE)?.last_mention).toBeUndefined()
    expect(bumps.every((b) => b.last_approval === undefined)).toBe(true)
    // A later row change (an edit of the last message) still describes the last message, so coalescing keeps the facts.
    const edit = { kind: "message.edit" as const, message_id: result.commit.message!.id, parts: [text("plain")] }
    const editBefore = host.head
    const editRequest = host.request(ALICE, "e1", edit)
    const edited = host.run(ALICE, "e1", edit)
    if (!edited.ok) throw new Error(edited.code)
    expect(fanOut({ before: editBefore, request: editRequest, commit: edited.commit }).bumps.find((b) => b.user === BOB)).toMatchObject({ last_seq: 1, last_author: ALICE, last_author_kind: "human" })
    // A chief author is an agent.
    const chief = host.run(CHIEF, "c1", { kind: "message.send", client_msg_id: "c1", parts: [text("done")] })
    if (!chief.ok) throw new Error(chief.code)
    const chiefBumps = fanOut({ before: host.head, request: host.request(CHIEF, "c1", { kind: "message.send", client_msg_id: "c1", parts: [text("done")] }), commit: chief.commit }).bumps
    expect(chiefBumps.find((b) => b.user === BOB)).toMatchObject({ last_author: CHIEF, last_author_kind: "agent" })
  })

  it("an approval notifies only its addressee: the owner of the agent that asked (home.md section 5)", () => {
    // The approval part type is not in the conversation vocabulary yet (validateParts refuses it), so the
    // committed message is given the part after the send, as a future send of the part would commit it.
    const withApproval = (author: string, id: string) => {
      const host = new CoreHost(groupHead())
      const before = host.head
      const op = { kind: "message.send" as const, client_msg_id: id, parts: [text("may I deploy?")] }
      const request = host.request(author, id, op)
      const result = host.run(author, id, op)
      if (!result.ok) throw new Error(result.code)
      const message = { ...result.commit.message!, parts: [...result.commit.message!.parts, { type: "approval" } as unknown as (typeof result.commit.message.parts)[number]] }
      return fanOut({ before, request, commit: { ...result.commit, message } }).bumps
    }
    const fromChief = withApproval(CHIEF, "a1")
    expect(fromChief.find((b) => b.user === ALICE)).toMatchObject({ last_author: CHIEF, last_author_kind: "agent", last_approval: true })
    // Another member of the group cannot decide the chief's approval: no alert through mute.
    expect(fromChief.find((b) => b.user === BOB)?.last_approval).toBeUndefined()
    // A human's message never carries the approval fact, whatever its parts.
    expect(withApproval(BOB, "a2").every((b) => b.last_approval === undefined)).toBe(true)
  })

  it("an approval bump is never coalesced away by a later bump of the same conversation", () => {
    const fan = {
      bumps: [{ user: BOB, conversation: "conv_GROUP", rev: 4, kind: "group" as const, title: "Team", last_seq: 3, last_at: "t", preview: "", last_author: CHIEF, last_author_kind: "agent" as const, last_approval: true as const }],
      wakes: [],
      search: [],
      deliveries: []
    }
    const [approval] = fanOutItems(fan, undefined, "group")
    expect(approval?.target).toEqual({ class: "UserDO", name: BOB })
    const [plain] = fanOutItems({ ...fan, bumps: [{ ...fan.bumps[0]!, last_approval: undefined }] }, undefined, "group")
    expect(plain?.target).toEqual({ class: "UserDO", name: BOB, coalesce: "bump:conv_GROUP" })
  })

  it("truncates previews and search bodies, and removes the bump target that left", () => {
    const host = new CoreHost(groupHead())
    const long = "é".repeat(SEARCH_BODY_BYTES)
    const message = host.send(ALICE, "m1", long)
    expect([...previewOf(host.head, message)]).toHaveLength(PREVIEW_CHARS)
    const before = host.head
    const request = host.request(BOB, "x", { kind: "participants.remove", participant: BOB })
    const result = host.run(BOB, "x", { kind: "participants.remove", participant: BOB })
    if (!result.ok) throw new Error(result.code)
    expect(fanOut({ before, request, commit: result.commit }).bumps.map((b) => [b.user, b.removed ?? false])).toEqual([
      [ALICE, false],
      [BOB, true]
    ])
    const sendBefore = host.head
    const sendRequest = host.request(ALICE, "m2", { kind: "message.send", client_msg_id: "m2", parts: [text(long)] })
    const sent = host.run(ALICE, "m2", { kind: "message.send", client_msg_id: "m2", parts: [text(long)] })
    if (!sent.ok) throw new Error(sent.code)
    const search = fanOut({ before: sendBefore, request: sendRequest, commit: sent.commit }).search[0]
    expect(search?.op === "upsert" && utf8Bytes(search.row.body)).toBe(SEARCH_BODY_BYTES)
  })
})
