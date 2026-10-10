import { dmConversationId } from "../src/conversation/ids.ts"
import { SYSTEM_ACTOR, type Op } from "../src/conversation/types.ts"
import { agent, CoreHost, human, NOW, text } from "../test/support/harness.ts"
import { ALICE, BOB, CAROL, CHIEF, chiefHead, ADDRESS, ADDRESS2, dmHead, groupHead, INV, INV2, inviteOp, tokenHash } from "../test/support/cloud.ts"
import type { Corpus } from "./generate.ts"
import { questionPart } from "./question-cases.ts"

/** Cloud extensions: kinds, roles, addresses, leave/remove, invites, delivery, settings. */
export const cloudCases = (c: Corpus): void => {
  const address = (id: string) => ({ id, kind: "address" as const, display_name: "dana@" })
  const group = { id: "conv_01J00000000000000000GROUP", actor: ALICE, title: "Team", now: NOW, kind: "group" as const }
  c.create("create group: roles, settings, state", { ...group, participants: [human(ALICE, "Alice"), human(BOB, "Bob"), agent(CHIEF, ALICE)] }, "commit")
  c.create("create group: untitled is allowed", { ...group, title: "", participants: [human(ALICE)] }, "commit")
  c.create("create group: addresses join only by invite", { ...group, participants: [human(ALICE), address(ADDRESS)] }, "invalid_participant")
  c.create("create group: a paired device never joins a cloud head", { ...group, participants: [human(ALICE), { ...human("remote_inst_1"), person: ALICE } as never] }, "invalid_participant")
  c.create("create group: custom settings", { ...group, participants: [human(ALICE)], settings: { wake_policy: "mentions", history_visible: "since_join" } }, "commit")
  c.create("create group: bad settings", { ...group, participants: [human(ALICE)], settings: { wake_policy: "loud" as never } }, "invalid_settings")
  const dm = { actor: ALICE, title: "", now: NOW, kind: "dm" as const }
  c.create("create dm: deterministic id", { ...dm, id: dmConversationId(ALICE, BOB), participants: [human(ALICE), human(BOB)] }, "commit")
  c.create("create dm: wrong id", { ...dm, id: "conv_dm_WRONG", participants: [human(ALICE), human(BOB)] }, "invalid_conversation_id")
  c.create("create dm: with a address peer", { ...dm, id: dmConversationId(ALICE, ADDRESS), participants: [human(ALICE), address(ADDRESS)] }, "commit")
  c.create("create dm: three people", { ...dm, id: dmConversationId(ALICE, BOB), participants: [human(ALICE), human(BOB), human(CAROL)] }, "invalid_participant")
  c.create("create chief: owner and one mux", { id: "conv_CHIEF", actor: ALICE, title: "Chief", now: NOW, kind: "chief", participants: [human(ALICE), agent(CHIEF, ALICE)] }, "commit")
  c.create("create chief: no agent", { id: "conv_CHIEF", actor: ALICE, title: "Chief", now: NOW, kind: "chief", participants: [human(ALICE), human(BOB)] }, "invalid_participant")

  const host = new CoreHost(groupHead())
  const send = (key: string, body: string): Op => ({ kind: "message.send", client_msg_id: key, parts: [text(body)] })
  c.op(host, "send: by a member", BOB, "m1", send("m1", "hello"), "commit")
  c.op(host, "send: a cloud head refuses a paired-device mention", BOB, "m1d", { kind: "message.send", client_msg_id: "m1d", parts: [{ type: "text", text: "hi", runs: [{ start: 0, length: 2, mention: "remote_inst_1" }] }] }, "invalid_parts")
  c.op(host, "participants.add: stamps role, joined_seq, added_by", BOB, "p1", { kind: "participants.add", participant: human(CAROL, "Carol") }, "commit")
  c.op(host, "participants.add: a address", BOB, "p2", { kind: "participants.add", participant: address(ADDRESS) }, "invalid_participant")
  c.op(host, "participants.remove: a member may not remove another", BOB, "r1", { kind: "participants.remove", participant: CAROL }, "forbidden")
  c.op(host, "participants.remove: unknown participant", ALICE, "r2", { kind: "participants.remove", participant: "user_nobody" }, "unknown_participant")
  c.op(host, "participants.remove: the chief's owner removes the chief", ALICE, "r3", { kind: "participants.remove", participant: CHIEF }, "commit")
  c.op(host, "send: a departed chief", CHIEF, "m2", send("m2", "still here?"), "not_participant")
  c.op(host, "participants.add: a member re-adds another user's chief", BOB, "p3", { kind: "participants.add", participant: agent(CHIEF, BOB) }, "forbidden")
  c.op(host, "participants.add: the actor's own new agent (the Domain stamps owner_user from its policy)", BOB, "p4", { kind: "participants.add", participant: agent("agent_bobchief", BOB) }, "commit")
  c.op(host, "participants.add: someone else's new chief", CAROL, "p5", { kind: "participants.add", participant: agent("agent_x", ALICE) }, "forbidden")
  c.op(host, "participants.add: the host approved the participant", CAROL, "p6", { kind: "participants.add", participant: agent("agent_x", ALICE) }, "commit", {
    trusted_participant: true
  })
  c.op(host, "participants.add: the chief's owner re-adds it", ALICE, "p7", { kind: "participants.add", participant: agent(CHIEF, ALICE) }, "commit")
  c.op(host, "invite.create: email to a new address", BOB, "i1", inviteOp(), "commit")
  c.op(host, "send: a address cannot act", ADDRESS, "m3", send("m3", "hi"), "address_cannot_act")
  c.op(host, "invite.create: a chief cannot invite", CHIEF, "i2", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: tokenHash("s2") }), "forbidden")
  c.op(host, "invite.create: the address already has an open invite", ALICE, "i3", inviteOp({ invite_id: INV2, token_hash: tokenHash("s2") }), "duplicate_invite")
  c.op(host, "invite.create: malformed token hash", ALICE, "i4", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: "short" }), "invalid_invite")
  c.op(host, "invite.delivery.report: by a user", ALICE, "d0", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "sent" } }, "forbidden")
  c.op(host, "invite.delivery.report: provider_id null", SYSTEM_ACTOR, "d1", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "sent", provider_id: null as never } }, "invalid_invite")
  c.op(host, "invite.delivery.report: sent", SYSTEM_ACTOR, "d1", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "sent", provider_id: "re_123" } }, "commit")
  c.op(host, "invite.delivery.report: backwards", SYSTEM_ACTOR, "d2", { kind: "invite.delivery.report", invite_id: INV, delivery: { state: "queued" } }, "delivery_regression")
  c.op(host, "invite.accept: the inviter", BOB, "a0", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Bob" }, "invite_self")
  c.op(host, "invite.accept: unknown hash", "user_dave", "a1", { kind: "invite.accept", token_hash: tokenHash("nope"), display_name: "Dave" }, "unknown_invite")
  c.op(host, "invite.accept: unverified email waits for approval", "user_dave", "a2", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Dave" }, "commit")
  c.op(host, "invite.accept: a second holder", "user_erin", "a3", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Erin" }, "invite_not_pending")
  c.op(host, "invite.approve_join: a member who is not the inviter", CAROL, "ap0", { kind: "invite.approve_join", invite_id: INV }, "forbidden")
  c.op(host, "invite.approve_join: malformed approve", BOB, "ap1", { kind: "invite.approve_join", invite_id: INV, approve: "yes" as never }, "invalid_invite")
  c.op(host, "invite.approve_join: the inviter", BOB, "ap2", { kind: "invite.approve_join", invite_id: INV }, "commit")
  c.op(host, "invite.revoke: an accepted invite", ALICE, "v0", { kind: "invite.revoke", invite_id: INV }, "invite_not_pending")
  c.op(host, "invite.create: sms to another address", CAROL, "i5", inviteOp({ invite_id: INV2, address: ADDRESS2, channel: "sms", token_hash: tokenHash("s2") }), "commit")
  c.op(host, "invite.revoke: a member who is not the inviter", BOB, "v1", { kind: "invite.revoke", invite_id: INV2 }, "forbidden")
  c.op(host, "invite.revoke: the owner; the address is dropped from the head", ALICE, "v2", { kind: "invite.revoke", invite_id: INV2 }, "commit")
  c.op(host, "invite.accept: by an agent", CHIEF, "a4", { kind: "invite.accept", token_hash: tokenHash("s2"), display_name: "Chief" }, "invalid_participant")
  c.op(host, "settings: a member", BOB, "s0", { kind: "conversation.settings.set", wake_policy: "all" }, "forbidden")
  c.op(host, "settings: nothing to set", ALICE, "s1", { kind: "conversation.settings.set" }, "invalid_settings")
  c.op(host, "settings: two agent turns", ALICE, "s2", { kind: "conversation.settings.set", agent_budget: { turns: 2, gap_ms: 0 } }, "commit")
  c.op(host, "loop guard: first chief text turn", CHIEF, "b1", send("b1", "one"), "commit")
  c.op(host, "loop guard: work cards neither count nor reset", CHIEF, "w1", { kind: "message.send", client_msg_id: "w1", parts: [{ type: "work", session: "s", status: "running" }] }, "commit")
  c.op(host, "loop guard: second chief text turn", CHIEF, "b2", send("b2", "two"), "commit")
  for (let card = 2; card <= 7; card++) {
    c.op(host, `loop guard: work card ${card}`, CHIEF, `w${card}`, { kind: "message.send", client_msg_id: `w${card}`, parts: [{ type: "work", session: "s", status: "done" }] }, "commit")
  }
  c.op(host, "loop guard: a third text turn after many work cards", CHIEF, "b3", send("b3", "three"), "agent_budget")
  c.op(host, "loop guard: a human text message resets the streak", BOB, "h1", send("h1", "go on"), "commit")
  c.op(host, "loop guard: the chief may speak again", CHIEF, "b4", send("b4", "four"), "commit")
  c.op(host, "participants.remove: the owner leaves, Bob becomes owner", ALICE, "l1", { kind: "participants.remove", participant: ALICE }, "commit")
  for (const [index, user] of [BOB, CAROL, "user_dave"].entries()) {
    c.op(host, `participants.remove: ${user} leaves`, user, `l${index + 2}`, { kind: "participants.remove", participant: user }, "commit")
  }
  c.op(host, "archived: the chief cannot send", CHIEF, "x1", send("x1", "anyone?"), "archived")

  const verified = new CoreHost(groupHead())
  c.op(verified, "invite.create: email", ALICE, "i1", inviteOp(), "commit")
  verified.now = "2026-10-02T12:00:00.000Z"
  c.op(verified, "invite.accept: verified address binds at once", CAROL, "a1", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Carol" }, "commit", {
    actor_addresses: [ADDRESS]
  })
  const approval = new CoreHost(groupHead())
  c.op(approval, "invite.create: sms in a group", ALICE, "i1", inviteOp({ channel: "sms" }), "commit")
  c.op(approval, "invite.accept: a group sms invite always waits for approval", CAROL, "a1", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Carol" }, "commit", {
    actor_addresses: [ADDRESS]
  })
  approval.now = "2026-10-15T12:00:00.000Z"
  c.op(approval, "invite.approve_join: after the expiry", ALICE, "ap1", { kind: "invite.approve_join", invite_id: INV }, "invite_expired")
  c.op(approval, "invite.create: closes the expired invite and drops its address", ALICE, "i2", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: tokenHash("s2") }), "commit")
  const decline = new CoreHost(groupHead())
  c.op(decline, "decline: invite.create email", ALICE, "i1", inviteOp(), "commit")
  c.op(decline, "decline: invite.accept unverified", CAROL, "a1", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Carol" }, "commit")
  c.op(decline, "invite.approve_join: decline closes the invite", ALICE, "ap1", { kind: "invite.approve_join", invite_id: INV, approve: false }, "commit")
  c.op(decline, "invite.approve_join: after a decline", ALICE, "ap2", { kind: "invite.approve_join", invite_id: INV }, "invite_not_pending")
  const late = new CoreHost(groupHead())
  c.op(late, "invite.create: sms", ALICE, "i1", inviteOp({ channel: "sms" }), "commit")
  late.now = "2026-10-15T12:00:00.000Z"
  c.op(late, "invite.accept: at the expiry", CAROL, "a1", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Carol" }, "invite_expired")

  const dmHost = new CoreHost(dmHead(ADDRESS))
  c.op(dmHost, "dm: invite a address that is not the peer", ALICE, "i0", inviteOp({ invite_id: INV2, address: ADDRESS2 }), "kind_forbids")
  c.op(dmHost, "dm: invite the address peer", ALICE, "i1", inviteOp(), "commit")
  c.op(dmHost, "dm: any holder binds once", CAROL, "a1", { kind: "invite.accept", token_hash: tokenHash("secret-1"), display_name: "Carol" }, "commit")
  c.op(dmHost, "dm: title.set", ALICE, "t1", { kind: "title.set", title: "x" }, "kind_forbids")
  c.op(dmHost, "dm: participants.remove", ALICE, "r1", { kind: "participants.remove", participant: CAROL }, "kind_forbids")

  const chief = new CoreHost(chiefHead())
  c.op(chief, "chief: participants.add", ALICE, "p1", { kind: "participants.add", participant: human(BOB) }, "kind_forbids")
  c.op(chief, "chief: invite.create", ALICE, "i1", inviteOp(), "kind_forbids")
  // Questions follow the local rules on a cloud head: the chief asks, its owner answers.
  c.op(chief, "chief: the owner may not post a question", ALICE, "q1", { kind: "message.send", client_msg_id: "q1", parts: [questionPart()] }, "invalid_parts")
  c.op(chief, "chief: the chief posts a question", CHIEF, "q1", { kind: "message.send", client_msg_id: "q1", parts: [questionPart()] }, "commit")
  const asked = chief.messages.at(-1)!.id
  const answer = (selections: unknown): Op => ({ kind: "question.answer", message_id: asked, part_index: 0, answer: { selections } }) as never
  c.op(chief, "chief: the chief may not answer", CHIEF, "a1", answer({ q0: { option_ids: ["oauth"] } }), "human_only")
  c.op(chief, "chief: the owner answers", ALICE, "a1", answer({ q0: { option_ids: ["oauth"] } }), "commit")
  c.op(chief, "chief: a second answer", ALICE, "a2", answer({ q0: { option_ids: ["keys"] } }), "question_closed")

  const local = new CoreHost()
  c.op(local, "local head: cloud ops are unsupported", "user_local", "s1", { kind: "conversation.settings.set", wake_policy: "all" }, "unsupported_op")
}
