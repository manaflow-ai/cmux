import type { Op, Part } from "../src/conversation/types.ts"
import { agent, CoreHost, human, NOW, text } from "../test/support/harness.ts"
import type { Corpus } from "./generate.ts"

/**
 * The Rust crate's local subset: heads without `kind`, the eight ops, create and the agent
 * loop guard. REQUIRED check for the Rust owner: heads carry `agent_text_streak` (0 at
 * create) and `last_agent_text_at`, updated on every text send (agent +1, human resets).
 */
export const localCases = (c: Corpus): void => {
  const ALICE = "user_local"
  const MUX = "agent_mux"
  const EVE = "user_eve"
  const parts = (...values: Array<string>): Array<Part> => values.map(text)
  const send = (key: string, p: Array<Part>, reply_to?: { message_id: string; part_index: number }): Op => ({
    kind: "message.send",
    client_msg_id: key,
    parts: p,
    ...(reply_to ? { reply_to } : {})
  })
  const base = { id: "conv_01J0000000000000000000TEST", actor: ALICE, title: "mux", now: NOW }

  c.create("create: a human and the mux", { ...base, participants: [human(ALICE), agent(MUX)] }, "commit")
  c.create("create: the actor must be a participant", { ...base, actor: EVE, participants: [human(ALICE)] }, "not_participant")
  c.create("create: empty title", { ...base, title: "", participants: [human(ALICE)] }, "invalid_title")
  c.create("create: 201 character title", { ...base, title: "x".repeat(201), participants: [human(ALICE)] }, "invalid_title")
  c.create("create: 200 non-ASCII characters fit", { ...base, title: "é".repeat(200), participants: [human(ALICE)] }, "commit")
  c.create("create: no participants", { ...base, participants: [] }, "invalid_participant")
  c.create("create: duplicate participant", { ...base, participants: [human(ALICE), human(ALICE)] }, "duplicate_participant")
  c.create("create: a human with an agent id", { ...base, participants: [human(ALICE), human(MUX)] }, "invalid_participant")

  const host = new CoreHost()
  c.op(host, "send: first message gets seq 1", ALICE, "c1", send("c1", parts("hi")), "commit")
  const first = host.messages[0]!
  c.op(host, "send: client_msg_id must equal the idempotency key", ALICE, "other", send("c2", parts("x")), "invalid_client_msg_id")
  c.op(host, "send: an outsider is refused", EVE, "c3", send("c3", parts("x")), "not_participant")
  c.op(host, "send: empty parts", ALICE, "c4", send("c4", []), "invalid_parts")
  c.op(host, "send: 17 parts", ALICE, "c4", send("c4", Array.from({ length: 17 }, () => text("x"))), "invalid_parts")
  c.op(host, "send: empty text", ALICE, "c4", send("c4", [text("")]), "invalid_parts")
  c.op(host, "send: a run past the UTF-16 end", ALICE, "c4", send("c4", [{ type: "text", text: "héllo", runs: [{ start: 3, length: 3 }] }]), "invalid_parts")
  c.op(host, "send: a mention that is no participant id", ALICE, "c4", send("c4", [{ type: "text", text: "hi", runs: [{ start: 0, length: 2, mention: "nobody" }] }]), "invalid_parts")
  c.op(host, "send: a work part with an empty session", ALICE, "c4", send("c4", [{ type: "work", session: "", status: "running" }]), "invalid_parts")
  c.op(
    host,
    "send: a mention and an emoji run in UTF-16 units",
    ALICE,
    "c5",
    send("c5", [{ type: "text", text: "@mux 👋", runs: [{ start: 0, length: 4, mention: MUX }, { start: 5, length: 2, link: "https://cmux.com" }] }]),
    "commit"
  )
  c.op(host, "send: a work card", MUX, "c6", send("c6", [{ type: "work", session: "child", host: "mac", status: "running", preview: "building" }, text("on it")]), "commit")
  c.op(host, "send: reply to an unknown message", MUX, "c7", send("c7", parts("answer"), { message_id: "msg_nope", part_index: 0 }), "unknown_message")
  c.op(host, "send: reply to a part that does not exist", MUX, "c7", send("c7", parts("answer"), { message_id: first.id, part_index: 1 }), "invalid_part_index")
  // The 2 s agent gap applies to every head now; step past it before the next agent text.
  host.advance(2_000)
  c.op(host, "send: reply to an existing part", MUX, "c7", send("c7", parts("answer"), { message_id: first.id, part_index: 0 }), "commit")

  const love = { tapback: "love" as const }
  const workCard = host.messages[2]!
  c.op(host, "reaction.add: a tapback", ALICE, "a1", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: love }, "commit")
  c.op(host, "reaction.add: the same tapback by another author", MUX, "a2", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: love }, "commit")
  c.op(host, "reaction.add: a duplicate", MUX, "a3", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: love }, "duplicate_reaction")
  c.op(host, "reaction.add: an emoji", MUX, "a4", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: { emoji: "🎉" } }, "commit")
  c.op(host, "reaction.add: an empty emoji", ALICE, "a5", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: { emoji: "" } }, "invalid_reaction")
  c.op(host, "reaction.add: an emoji with a space", ALICE, "a5", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: { emoji: "a b" } }, "invalid_reaction")
  c.op(host, "reaction.add: a part that does not exist", ALICE, "a6", { kind: "reaction.add", message_id: first.id, part_index: 1, reaction: love }, "invalid_part_index")
  c.op(host, "reaction.add: on part 1 of the work card", ALICE, "a7", { kind: "reaction.add", message_id: workCard.id, part_index: 1, reaction: love }, "commit")
  c.op(host, "reaction.remove: another author's reaction", ALICE, "d0", { kind: "reaction.remove", message_id: first.id, part_index: 0, reaction: { emoji: "🎉" } }, "unknown_reaction")
  c.op(host, "reaction.remove: own tapback", ALICE, "d1", { kind: "reaction.remove", message_id: first.id, part_index: 0, reaction: love }, "commit")
  c.op(host, "reaction.remove: no such reaction", ALICE, "d2", { kind: "reaction.remove", message_id: first.id, part_index: 0, reaction: love }, "unknown_reaction")
  c.op(host, "reaction.remove: unknown message", ALICE, "d3", { kind: "reaction.remove", message_id: "msg_nope", part_index: 0, reaction: love }, "unknown_message")

  c.op(host, "edit: not the author", ALICE, "e1", { kind: "message.edit", message_id: workCard.id, parts: parts("x") }, "not_author")
  c.op(host, "edit: unknown message", MUX, "e1", { kind: "message.edit", message_id: "msg_missing", parts: parts("x") }, "unknown_message")
  c.op(host, "edit: invalid parts", MUX, "e1", { kind: "message.edit", message_id: workCard.id, parts: [] }, "invalid_parts")
  c.op(host, "edit: fewer parts drop reactions on removed parts", MUX, "e1", { kind: "message.edit", message_id: workCard.id, parts: parts("done") }, "commit")
  host.now = "2026-10-01T12:30:00.000Z"
  c.op(host, "retract: not the author", MUX, "r1", { kind: "message.retract", message_id: first.id }, "not_author")
  c.op(host, "retract: clears parts and reactions, keeps updated_at", ALICE, "r1", { kind: "message.retract", message_id: first.id }, "commit")
  c.op(host, "retract: twice", ALICE, "r2", { kind: "message.retract", message_id: first.id }, "retracted")
  c.op(host, "edit: a retracted message", ALICE, "e2", { kind: "message.edit", message_id: first.id, parts: parts("x") }, "retracted")
  c.op(host, "reaction.add: a retracted message", MUX, "a8", { kind: "reaction.add", message_id: first.id, part_index: 0, reaction: love }, "retracted")
  c.op(host, "reaction.remove: a retracted message", MUX, "d4", { kind: "reaction.remove", message_id: first.id, part_index: 0, reaction: love }, "retracted")

  c.op(host, "read_cursor.set: past last_seq", MUX, "rc0", { kind: "read_cursor.set", seq: host.head.last_seq + 1 }, "cursor_out_of_range")
  c.op(host, "read_cursor.set: to last_seq", MUX, "rc1", { kind: "read_cursor.set", seq: host.head.last_seq }, "commit")
  c.op(host, "read_cursor.set: backwards", MUX, "rc2", { kind: "read_cursor.set", seq: 1 }, "cursor_regression")
  c.op(host, "read_cursor.set: an outsider", EVE, "rc3", { kind: "read_cursor.set", seq: 1 }, "not_participant")

  c.op(host, "participants.add: a human, with the last message in the summary", ALICE, "p1", { kind: "participants.add", participant: human(EVE, "Eve") }, "commit")
  c.op(host, "participants.add: a duplicate", ALICE, "p2", { kind: "participants.add", participant: human(EVE, "Eve") }, "duplicate_participant")
  c.op(host, "participants.add: a control character in the name", ALICE, "p3", { kind: "participants.add", participant: human("user_zed", "a\u0007") }, "invalid_participant")
  c.op(host, "title.set: empty", EVE, "t1", { kind: "title.set", title: "" }, "invalid_title")
  c.op(host, "title.set: by a new participant", EVE, "t2", { kind: "title.set", title: "Team" }, "commit")

  // Agent budget: the head's counters (agent_text_streak, last_agent_text_at), no row window.
  const budget = new CoreHost()
  budget.send(ALICE, "h1", "go")
  for (let turn = 0; turn < 4; turn++) {
    budget.advance(10_000)
    c.op(budget, `budget: agent turn ${turn + 1} of 4`, MUX, `m${turn}`, send(`m${turn}`, parts(`turn ${turn}`)), "commit")
  }
  budget.advance(10_000)
  c.op(budget, "budget: a fifth agent turn", MUX, "m9", send("m9", parts("again")), "agent_budget")
  c.op(budget, "budget: a work card is never limited", MUX, "w1", send("w1", [{ type: "work", session: "s", status: "done" }]), "commit")
  c.op(budget, "budget: humans are never limited", ALICE, "h2", send("h2", parts("next")), "commit")
  c.op(budget, "budget: an agent after a human message", MUX, "m10", send("m10", parts("ok")), "commit")
  budget.advance(1_999)
  c.op(budget, "budget: within the 2 s gap", MUX, "m11", send("m11", parts("fast")), "agent_rate")
  c.op(budget, "budget: malformed parts report invalid_parts first", MUX, "m11", send("m11", []), "invalid_parts")
  budget.advance(1)
  c.op(budget, "budget: at the gap", MUX, "m11", send("m11", parts("now")), "commit")

  // The work-card bypass: text-less work cards between agent texts must not reset or hide the count.
  const cards = new CoreHost()
  cards.send(ALICE, "h1", "go")
  for (let turn = 0; turn < 4; turn++) {
    cards.advance(10_000)
    c.op(cards, `loop guard: agent text ${turn + 1} of 4 between work cards`, MUX, `t${turn}`, send(`t${turn}`, parts(`turn ${turn}`)), "commit")
    c.op(cards, `loop guard: work card ${turn + 1}`, MUX, `w${turn}`, send(`w${turn}`, [{ type: "work", session: "s", status: "running" }]), "commit")
  }
  cards.advance(10_000)
  c.op(cards, "loop guard: a fifth agent text after work cards is refused", MUX, "t9", send("t9", parts("again")), "agent_budget")
}
