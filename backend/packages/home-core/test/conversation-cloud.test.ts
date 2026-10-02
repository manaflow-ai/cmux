import { describe, expect, it } from "vitest"
import { create, dmConversationId, SYSTEM_ACTOR, type Op } from "../src/conversation/index.ts"
import { CoreHost, human, NOW, text } from "./support/harness.ts"
import { ALICE, BOB, CAROL, CHIEF, chiefHead, ADDRESS, ADDRESS2, dmHead, groupHead, INV, INV2, inviteOp, tokenHash } from "./support/cloud.ts"

const code = (result: { ok: boolean; code?: string }) => (result.ok ? "ok" : result.code)
const accept = (secret: string, name = "Dana"): Op => ({ kind: "invite.accept", token_hash: tokenHash(secret), display_name: name })

describe("cloud create", () => {
  it("stamps roles, state and default settings", () => {
    const head = groupHead()
    expect(head.kind).toBe("group")
    expect(head.state).toBe("active")
    expect(head.created_by).toBe(ALICE)
    expect(head.participants.map((p) => [p.id, p.role, p.joined_seq, p.added_by])).toEqual([
      [ALICE, "owner", 0, ALICE],
      [BOB, "member", 0, ALICE],
      [CHIEF, "member", 0, ALICE]
    ])
    expect(head.settings).toEqual({ wake_policy: "auto", agent_budget: { turns: 4, gap_ms: 2000 }, history_visible: "all" })
    expect(head.invites).toEqual([])
  })

  it("checks the shape of each kind", () => {
    const make = (kind: "dm" | "chief" | "group", id: string, participants: Array<unknown>, title = "") =>
      code(create({ id, actor: ALICE, title, participants: participants as never, now: NOW, kind }))
    expect(make("dm", dmConversationId(ALICE, BOB), [human(ALICE), human(BOB)])).toBe("ok")
    expect(make("dm", "conv_WRONG", [human(ALICE), human(BOB)])).toBe("invalid_conversation_id")
    expect(make("dm", dmConversationId(ALICE, CHIEF), [human(ALICE), { id: CHIEF, kind: "agent", display_name: "c", agent_class: "mux" }])).toBe(
      "invalid_participant"
    )
    expect(make("dm", dmConversationId(ALICE, ADDRESS), [human(ALICE), { id: ADDRESS, kind: "address", display_name: "d" }])).toBe("ok")
    expect(make("chief", "conv_C", [human(ALICE), human(BOB)])).toBe("invalid_participant")
    expect(make("group", "conv_G", [human(ALICE), { id: ADDRESS, kind: "address", display_name: "d" }])).toBe("invalid_participant")
    expect(make("group", "conv_G", [human(ALICE)], "")).toBe("ok")
    expect(code(create({ id: "conv_L", actor: ALICE, title: "", participants: [human(ALICE)], now: NOW }))).toBe("invalid_title")
  })
})

describe("cloud rules on local ops", () => {
  it("title.set and participants.add are refused on dm and chief conversations", () => {
    for (const head of [dmHead(), chiefHead()]) {
      const host = new CoreHost(head)
      expect(code(host.run(ALICE, "t", { kind: "title.set", title: "x" }))).toBe("kind_forbids")
      expect(code(host.run(ALICE, "p", { kind: "participants.add", participant: human(CAROL) }))).toBe("kind_forbids")
    }
  })

  it("participants.add stamps the joiner and refuses addresses", () => {
    const host = new CoreHost(groupHead())
    host.send(ALICE, "c1", "hi")
    expect(code(host.run(BOB, "p1", { kind: "participants.add", participant: { ...human(CAROL), role: "owner" } }))).toBe("ok")
    expect(host.head.participants.at(-1)).toEqual({ id: CAROL, kind: "human", display_name: "Alice", role: "member", joined_seq: 1, added_by: BOB })
    expect(code(host.run(ALICE, "p2", { kind: "participants.add", participant: { id: ADDRESS, kind: "address", display_name: "d" } }))).toBe(
      "invalid_participant"
    )
  })
})

describe("participants.remove", () => {
  it("leave, owner removal, chief owner removal, and archive when the last human leaves", () => {
    const host = new CoreHost(groupHead())
    expect(code(host.run(BOB, "r1", { kind: "participants.remove", participant: CHIEF }))).toBe("forbidden")
    expect(code(host.run(ALICE, "r2", { kind: "participants.remove", participant: CHIEF }))).toBe("ok")
    expect(code(host.run(CHIEF, "x", { kind: "message.send", client_msg_id: "x", parts: [text("hi")] }))).toBe("not_participant")
    expect(code(host.run(ALICE, "r3", { kind: "participants.remove", participant: "user_nobody" }))).toBe("unknown_participant")
    // The owner leaves: Bob inherits the owner role.
    expect(code(host.run(ALICE, "r4", { kind: "participants.remove", participant: ALICE }))).toBe("ok")
    expect(host.head.participants.find((p) => p.id === BOB)?.role).toBe("owner")
    expect(host.head.state).toBe("active")
    expect(code(host.run(BOB, "r5", { kind: "participants.remove", participant: BOB }))).toBe("ok")
    expect(host.head.state).toBe("archived")
  })

  it("is refused on dm and chief conversations", () => {
    expect(code(new CoreHost(dmHead()).run(ALICE, "r", { kind: "participants.remove", participant: ALICE }))).toBe("kind_forbids")
    expect(code(new CoreHost(chiefHead()).run(ALICE, "r", { kind: "participants.remove", participant: CHIEF }))).toBe("kind_forbids")
  })
})

describe("invites", () => {
  it("create adds a address that cannot act, and a pending invite with a 14 day expiry", () => {
    const host = new CoreHost(groupHead())
    expect(code(host.run(ALICE, "i1", inviteOp()))).toBe("ok")
    expect(host.head.participants.at(-1)).toMatchObject({ id: ADDRESS, kind: "address", role: "member", added_by: ALICE })
    expect(host.head.invites?.[0]).toMatchObject({ id: INV, status: "pending", expires_at: "2026-10-15T12:00:00.000Z", delivery: { state: "queued" } })
    for (const op of [
      { kind: "message.send", client_msg_id: "k", parts: [text("x")] },
      { kind: "read_cursor.set", seq: 0 },
      { kind: "title.set", title: "x" }
    ] as Array<Op>) {
      expect(code(host.run(ADDRESS, "k", op))).toBe("address_cannot_act")
    }
    expect(code(host.run(CHIEF, "i2", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: tokenHash("s2") })))).toBe("forbidden")
    expect(code(host.run(BOB, "i3", inviteOp({ invite_id: INV2, token_hash: tokenHash("s2") })))).toBe("duplicate_invite")
    expect(code(host.run(BOB, "i4", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: "short" })))).toBe("invalid_invite")
    expect(code(new CoreHost(chiefHead()).run(ALICE, "i", inviteOp()))).toBe("kind_forbids")
  })

  it("accept is single use, checks expiry, and replaces the address in place", () => {
    const host = new CoreHost(groupHead())
    host.run(ALICE, "i1", inviteOp())
    host.send(ALICE, "c1", "welcome")
    expect(code(host.run(ALICE, "a0", accept("secret-1")))).toBe("invite_self")
    expect(code(host.run(CAROL, "a1", accept("wrong")))).toBe("unknown_invite")
    expect(code(host.run(CAROL, "a2", accept("secret-1", "Carol"), { actor_addresses: [ADDRESS] }))).toBe("ok")
    const carol = host.head.participants.find((p) => p.id === CAROL)
    expect(carol).toEqual({ id: CAROL, kind: "human", display_name: "Carol", role: "member", joined_seq: 0, added_by: ALICE })
    expect(host.head.participants.some((p) => p.id === ADDRESS)).toBe(false)
    expect(host.head.invites?.[0]).toMatchObject({ status: "accepted", accepted_by: CAROL })
    expect(code(host.run("user_dave", "a3", accept("secret-1")))).toBe("invite_not_pending")
    const late = new CoreHost(groupHead())
    late.run(ALICE, "i1", inviteOp({ channel: "sms" }))
    late.now = "2026-10-15T12:00:00.000Z"
    expect(code(late.run(CAROL, "a", accept("secret-1")))).toBe("invite_expired")
  })

  it("a group email invite waits for approval unless the address is verified", () => {
    const host = new CoreHost(groupHead())
    host.run(ALICE, "i1", inviteOp())
    expect(code(host.run(CAROL, "a1", accept("secret-1", "Carol")))).toBe("ok")
    expect(host.head.invites?.[0]).toMatchObject({ status: "pending_approval", requested_by: CAROL })
    expect(host.head.participants.some((p) => p.id === CAROL)).toBe(false)
    expect(code(host.run("user_dave", "a2", accept("secret-1")))).toBe("invite_not_pending")
    expect(code(host.run(BOB, "ap1", { kind: "invite.approve_join", invite_id: INV }))).toBe("forbidden")
    expect(code(host.run(ALICE, "ap2", { kind: "invite.approve_join", invite_id: INV }))).toBe("ok")
    expect(host.head.participants.find((p) => p.id === CAROL)?.display_name).toBe("Carol")
    expect(host.head.invites?.[0]).toMatchObject({ status: "accepted", accepted_by: CAROL })
    expect(host.head.invites?.[0]).not.toHaveProperty("requested_by")
    const verified = new CoreHost(groupHead())
    verified.run(ALICE, "i1", inviteOp())
    expect(code(verified.run(CAROL, "a", accept("secret-1", "Carol"), { actor_addresses: [ADDRESS] }))).toBe("ok")
    expect(verified.head.invites?.[0]?.status).toBe("accepted")
  })

  it("a dm invite binds any holder once", () => {
    const host = new CoreHost(dmHead(ADDRESS))
    expect(code(host.run(ALICE, "i1", inviteOp({ invite_id: INV2, address: ADDRESS2 })))).toBe("kind_forbids")
    expect(code(host.run(ALICE, "i2", inviteOp()))).toBe("ok")
    expect(code(host.run(CAROL, "a", accept("secret-1", "Carol")))).toBe("ok")
    expect(host.head.participants.map((p) => p.id)).toEqual([ALICE, CAROL])
  })

  it("revoke and remove end open invites; delivery only moves forward", () => {
    const host = new CoreHost(groupHead())
    host.run(ALICE, "i1", inviteOp())
    expect(code(host.run(SYSTEM_ACTOR, "d0", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "sent", provider_id: "p1" } }))).toBe("ok")
    expect(code(host.run(ALICE, "d1", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "delivered" } }))).toBe("forbidden")
    expect(code(host.run(SYSTEM_ACTOR, "d2", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "queued" } }))).toBe("delivery_regression")
    const delivered = host.run(SYSTEM_ACTOR, "d3", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "delivered" } })
    expect(delivered.ok && delivered.commit.change).toMatchObject({ kind: "invite", invite: { delivery: { state: "delivered", provider_id: "p1" } } })
    expect(delivered.ok && "token_hash" in (delivered.commit.change as { invite: object }).invite).toBe(false)
    expect(code(host.run(BOB, "v1", { kind: "invite.revoke", invite_id: INV }))).toBe("forbidden")
    expect(code(host.run(ALICE, "v2", { kind: "invite.revoke", invite_id: INV }))).toBe("ok")
    // A departed address outside a dm is dropped from the head.
    expect(host.head.participants.some((p) => p.id === ADDRESS)).toBe(false)
    expect(code(host.run(CAROL, "a", accept("secret-1")))).toBe("invite_not_pending")
    host.run(ALICE, "i2", inviteOp({ invite_id: INV2, token_hash: tokenHash("s2") }))
    expect(host.head.participants.find((p) => p.id === ADDRESS)?.left_at).toBeUndefined()
    expect(code(host.run(SYSTEM_ACTOR, "dn", { kind: "invite.delivery.report", invite_id: INV2, delivery: { state: "sent", provider_id: null as never } }))).toBe("invalid_invite")
    expect(code(host.run(ALICE, "rm", { kind: "participants.remove", participant: ADDRESS }))).toBe("ok")
    expect(host.head.invites?.find((i) => i.id === INV2)?.status).toBe("revoked")
  })

  it("caps open invites at 20 and expires stale ones on the next create", () => {
    const host = new CoreHost(groupHead())
    for (let i = 0; i < 20; i++) {
      const suffix = `0${"0123456789ABCDEFGHJKMNPQRSTVWXYZ"[i]}`
      const r = host.run(ALICE, `i${i}`, inviteOp({ invite_id: `inv_${"0".repeat(24)}${suffix}`, address: `addr_${"0".repeat(24)}${suffix}`, token_hash: tokenHash(`s${i}`) }))
      expect(code(r)).toBe("ok")
    }
    const extra = inviteOp({ invite_id: `inv_${"1".repeat(26)}`, address: `addr_${"1".repeat(26)}`, token_hash: tokenHash("x") })
    expect(code(host.run(ALICE, "over", extra))).toBe("invite_limit")
    host.now = "2026-10-16T00:00:00.000Z"
    expect(code(host.run(ALICE, "later", extra))).toBe("ok")
    expect(host.head.invites?.filter((i) => i.status === "expired")).toHaveLength(20)
  })
})

describe("settings", () => {
  it("owner only, validated, merged", () => {
    const host = new CoreHost(groupHead())
    expect(code(host.run(BOB, "s1", { kind: "conversation.settings.set", wake_policy: "all" }))).toBe("forbidden")
    expect(code(host.run(ALICE, "s2", { kind: "conversation.settings.set" }))).toBe("invalid_settings")
    expect(code(host.run(ALICE, "s3", { kind: "conversation.settings.set", agent_budget: { turns: 0, gap_ms: 0 } }))).toBe("invalid_settings")
    expect(code(host.run(ALICE, "s4", { kind: "conversation.settings.set", history_visible: "since_join" }))).toBe("ok")
    expect(host.head.settings).toEqual({ wake_policy: "auto", agent_budget: { turns: 4, gap_ms: 2000 }, history_visible: "since_join" })
    expect(code(new CoreHost().run("user_local", "s", { kind: "conversation.settings.set", wake_policy: "all" }))).toBe("unsupported_op")
  })
})

describe("cloud agent rules", () => {
  it("only an agent's owner adds it, unless the host approved the participant", () => {
    const host = new CoreHost(groupHead())
    host.run(ALICE, "r", { kind: "participants.remove", participant: CHIEF })
    const add = { kind: "participants.add" as const, participant: { id: CHIEF, kind: "agent" as const, display_name: "c", agent_class: "mux" as const, owner_user: BOB } }
    expect(code(host.run(BOB, "p1", add))).toBe("forbidden")
    expect(code(host.run(BOB, "p2", add, { trusted_participant: true }))).toBe("ok")
    // The stored owner wins over the op's claim.
    expect(host.head.participants.find((p) => p.id === CHIEF)?.owner_user).toBe(ALICE)
  })

  it("the loop guard counts agent text turns in the head; work cards cannot hide them", () => {
    const host = new CoreHost(groupHead())
    const card: Op = { kind: "message.send", client_msg_id: "", parts: [{ type: "work", session: "s", status: "running" }] }
    host.send(ALICE, "h", "go")
    for (let turn = 0; turn < 4; turn++) {
      host.advance(5_000)
      host.send(CHIEF, `t${turn}`, "text")
      for (let i = 0; i < 6; i++) expect(code(host.run(CHIEF, `w${turn}-${i}`, { ...card, client_msg_id: `w${turn}-${i}` } as Op))).toBe("ok")
    }
    expect(host.head.agent_text_streak).toBe(4)
    host.advance(5_000)
    expect(code(host.run(CHIEF, "t5", { kind: "message.send", client_msg_id: "t5", parts: [text("again")] }))).toBe("agent_budget")
    host.send(BOB, "h2", "ok")
    expect(host.head.agent_text_streak).toBe(0)
    expect(code(host.run(CHIEF, "t6", { kind: "message.send", client_msg_id: "t6", parts: [text("again")] }))).toBe("ok")
    expect(code(host.run(CHIEF, "t7", { kind: "message.send", client_msg_id: "t7", parts: [text("fast")] }))).toBe("agent_rate")
  })
})

describe("join approval", () => {
  it("group sms invites always wait; decline closes the invite and drops the address; approval expires", () => {
    const host = new CoreHost(groupHead())
    host.run(ALICE, "i1", inviteOp({ channel: "sms" }))
    expect(code(host.run(CAROL, "a1", accept("secret-1", "Carol"), { actor_addresses: [ADDRESS] }))).toBe("ok")
    expect(host.head.invites?.[0]?.status).toBe("pending_approval")
    expect(code(host.run(ALICE, "d", { kind: "invite.approve_join", invite_id: INV, approve: false }))).toBe("ok")
    expect(host.head.invites?.[0]?.status).toBe("revoked")
    expect(host.head.participants.some((p) => p.id === ADDRESS || p.id === CAROL)).toBe(false)
    const late = new CoreHost(groupHead())
    late.run(ALICE, "i1", inviteOp())
    late.run(CAROL, "a1", accept("secret-1", "Carol"))
    late.now = "2026-10-15T12:00:00.000Z"
    expect(code(late.run(ALICE, "ap", { kind: "invite.approve_join", invite_id: INV }))).toBe("invite_expired")
  })
})
