import { MAX_AGENT_TURNS } from "../src/conversation/budget.ts"
import { create } from "../src/conversation/create.ts"
import type { Op, Part } from "../src/conversation/types.ts"
import { agent, CoreHost, human, NOW, text } from "../test/support/harness.ts"
import type { Corpus } from "./generate.ts"
import { questionCases, questionPart } from "./question-cases.ts"

/**
 * The Rust crate's local subset: heads without `kind`, the eight ops, create and the agent
 * loop guard. REQUIRED check for the Rust owner: heads carry `agent_text_streak` (0 at
 * create; the top level), `thread_agent_streaks` (per thread root, absent when empty) and
 * `last_agent_text_at`, updated on every text send in the message's thread (agent +1,
 * person resets that thread only).
 * The ninth op, `question.answer`, and the `question` part are in question-cases.ts.
 */
const createdHead = (request: Parameters<typeof create>[0]) => {
  const result = create(request)
  if (!result.ok) throw new Error(result.code)
  return result.head
}

export const localCases = (c: Corpus): void => {
  const ALICE = "user_local"
  const MUX = "agent_mux"
  const EVE = "user_eve"
  const parts = (...values: Array<string>): Array<Part> => values.map(text)
  const send = (key: string, p: Array<Part>, reply_to?: { message_id: string; part_index: number }, thread_root?: string): Op => ({
    kind: "message.send",
    client_msg_id: key,
    parts: p,
    ...(reply_to ? { reply_to } : {}),
    ...(thread_root ? { thread_root } : {})
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

  // Paired devices (server-remote-conversations.md section 5): a `remote_<install>` human names its
  // person. The reducer accepts it; only the daemon's pairing path creates one (hosts refuse it
  // from clients, and a cloud head never has one).
  const DEVICE = "remote_inst_1"
  const device = (person?: unknown) => ({ ...human(DEVICE, "Alice (MacBook)"), ...(person === undefined ? {} : { person }) }) as never
  c.create("create: a device of the local user", { ...base, participants: [human(ALICE), agent(MUX), device(ALICE)] }, "commit")
  c.create("create: a device without a person", { ...base, participants: [human(ALICE), device()] }, "invalid_participant")
  c.create("create: a device whose person is an agent", { ...base, participants: [human(ALICE), device(MUX)] }, "invalid_participant")
  c.create("create: a user with a person", { ...base, participants: [{ ...human(ALICE), person: EVE } as never] }, "invalid_participant")
  c.create("create: an agent with a person", { ...base, participants: [human(ALICE), { ...agent(MUX), person: ALICE } as never] }, "invalid_participant")
  c.create("create: a device as an agent", { ...base, participants: [human(ALICE), { ...agent(MUX), id: DEVICE } as never] }, "invalid_participant")
  const paired = new CoreHost()
  c.op(paired, "participants.add: a device of the local user", ALICE, "d0", { kind: "participants.add", participant: device(ALICE) }, "commit")
  paired.send(ALICE, "d1", "from the Mac")
  const local = paired.messages[0]!
  c.op(paired, "device: sends as its own participant", DEVICE, "d2", send("d2", parts("from the MacBook")), "commit")
  // The owner stamps the origin of a device message from its actor (the reducer never does).
  const sent = paired.messages[1]!
  paired.messages[1] = { ...sent, origin: { kind: "remote", install: "inst_1" } }
  c.op(paired, "device: edits its own message, the origin stays", DEVICE, "d3", { kind: "message.edit", message_id: sent.id, parts: parts("edited") }, "commit")
  c.op(paired, "device: cannot edit the local user's message", DEVICE, "d4", { kind: "message.edit", message_id: local.id, parts: parts("mine") }, "not_author")
  c.op(paired, "device: a reaction keeps the target's origin", DEVICE, "d5", { kind: "reaction.add", message_id: local.id, part_index: 0, reaction: { tapback: "like" } }, "commit")
  c.op(paired, "device: a mention of a device is valid", ALICE, "d6", send("d6", [{ type: "text", text: "hi", runs: [{ start: 0, length: 2, mention: DEVICE }] }]), "commit")

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

  // Threads (cx-59n8.4): thread_root names a top-level message of this conversation; a thread
  // has one level. A send moves the sender's read cursor to its seq only when the sender had read
  // everything before it (cursor >= last_seq); a sender behind keeps its cursor.
  const threads = new CoreHost()
  const root = threads.send(ALICE, "th0", "root")
  c.op(threads, "thread: the agent reads the root", MUX, "th0r", { kind: "read_cursor.set", seq: 1 }, "commit")
  c.op(threads, "thread: a caught-up sender's reply carries thread_root and moves its cursor", MUX, "th1", send("th1", parts("in thread"), undefined, root.id), "commit")
  const reply = threads.messages[1]!
  threads.advance(2_000)
  c.op(threads, "thread: a human behind the last seq replies and keeps its cursor", ALICE, "th2", send("th2", parts("me too"), undefined, root.id), "commit")
  c.op(threads, "thread: read_cursor.set catches the human up", ALICE, "th3", { kind: "read_cursor.set", seq: threads.head.last_seq }, "commit")
  c.op(threads, "thread: reply_to and thread_root together; the caught-up sender's cursor moves", ALICE, "th4", send("th4", parts("quoting"), { message_id: reply.id, part_index: 0 }, root.id), "commit")
  // Nested threads (conversation-tree-v1): a parent in a thread passes its root on; a named root must be the parent's own.
  c.op(threads, "thread: a reply to a thread reply with no root joins the parent's thread", ALICE, "th9", send("th9", parts("nested"), { message_id: reply.id, part_index: 0 }), "commit")
  c.op(threads, "thread: a named root that is not the parent's own is refused", ALICE, "th5", send("th5", parts("x"), { message_id: reply.id, part_index: 0 }, "msg_other"), "invalid_thread_root", { thread_target: { ...root, id: "msg_other" } })
  c.op(threads, "thread: the parent itself as the root", ALICE, "th10", send("th10", parts("to the root"), { message_id: root.id, part_index: 0 }, root.id), "commit")
  c.op(threads, "thread: an unknown root", ALICE, "th5", send("th5", parts("x"), undefined, "msg_nope"), "invalid_thread_root")
  c.op(threads, "thread: a root that is itself in a thread", ALICE, "th5", send("th5", parts("x"), undefined, reply.id), "invalid_thread_root")
  c.op(threads, "thread: a root of another conversation", ALICE, "th5", send("th5", parts("x"), undefined, root.id), "invalid_thread_root", {
    thread_target: { ...root, conversation: "conv_OTHER" }
  })
  c.op(threads, "thread: an outsider is refused before the root", EVE, "th5", send("th5", parts("x"), undefined, "msg_nope"), "not_participant")
  c.op(threads, "thread: a bad reply_to is reported before a bad root", ALICE, "th5", send("th5", parts("x"), { message_id: "msg_nope", part_index: 0 }, "msg_nope"), "unknown_message")
  c.op(threads, "thread: a loaded root with another id", ALICE, "th5", send("th5", parts("x"), undefined, "msg_other"), "invalid_thread_root", { thread_target: root })
  c.op(threads, "thread: a null thread_root is no thread", ALICE, "th5", { kind: "message.send", client_msg_id: "th5", parts: parts("plain"), thread_root: null } as unknown as Op, "commit")
  // A sender behind the last seq keeps its cursor: the agent's unhandled message stays unread to it.
  threads.advance(2_000)
  c.op(threads, "thread: a sender behind the last seq keeps its cursor", MUX, "th8", send("th8", parts("late answer"), undefined, root.id), "commit")
  c.op(threads, "thread: retract the root", ALICE, "th6", { kind: "message.retract", message_id: root.id }, "commit")
  c.op(threads, "thread: a reply to a retracted root is accepted", ALICE, "th7", send("th7", parts("still here"), undefined, root.id), "commit")

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

  // Thread objects (conversation-thread-objects-v1): a title, a status and an owner on the root.
  // Any participant sets them, the Chief too; the change is message-updated with the root, and
  // updated_at and the loop guard stay. A resolution stamps the head's last_seq; readers derive
  // the status (a later live reply reopens the thread), so the reducer never writes on a reply.
  const objects = new CoreHost()
  const top = objects.send(ALICE, "o0", "root")
  // Later than the send, so a commit that moved updated_at would differ from the head's.
  objects.advance(60_000)
  const update = (fields: Record<string, unknown>, root = top.id): Op => ({ kind: "thread.update", root, ...fields }) as never
  c.op(objects, "thread.update: a message with no replies becomes a titled thread", ALICE, "o1", update({ title: "Ship 1.0" }), "commit")
  c.op(objects, "thread.update: the Chief replies in the thread", MUX, "o2", send("o2", parts("on it"), undefined, top.id), "commit")
  const inThread = objects.messages[1]!
  c.op(objects, "thread.update: the Chief takes ownership", MUX, "o3", update({ owner: MUX }), "commit")
  c.op(objects, "thread.update: the Chief resolves at the head's last seq", MUX, "o4", update({ status: "resolved" }), "commit")
  c.op(objects, "thread.update: a reply after the resolution leaves the root as it is", ALICE, "o5", send("o5", parts("one more"), undefined, top.id), "commit")
  c.op(objects, "thread.update: a human resolves again, title and owner stay", ALICE, "o6", update({ status: "resolved", owner: ALICE }), "commit")
  c.op(objects, "thread.update: reopen clears the resolution", ALICE, "o7", update({ status: "open" }), "commit")
  c.op(objects, "thread.update: 200 non-ASCII characters fit", ALICE, "o8", update({ title: "é".repeat(200) }), "commit")
  c.op(objects, "thread.update: null fields are absent", ALICE, "o9", update({ title: null, status: null, owner: "" }), "commit")
  c.op(objects, "thread.update: an empty title clears the object", ALICE, "o10", update({ title: "" }), "commit")
  c.op(objects, "thread.update: a thread reply is no root", ALICE, "o11", update({ title: "x" }, inThread.id), "invalid_thread_root")
  c.op(objects, "thread.update: an unknown root", ALICE, "o11", update({ title: "x" }, "msg_nope"), "unknown_message")
  c.op(objects, "thread.update: a root of another conversation", ALICE, "o11", update({ title: "x" }), "unknown_message", { target: { ...top, conversation: "conv_OTHER" } })
  c.op(objects, "thread.update: nothing to set", ALICE, "o11", update({}), "invalid_thread_update")
  c.op(objects, "thread.update: only null fields", ALICE, "o11", update({ title: null, owner: null }), "invalid_thread_update")
  c.op(objects, "thread.update: an owner who is no participant", ALICE, "o11", update({ owner: EVE }), "invalid_thread_owner")
  c.op(objects, "thread.update: a 201 character title", ALICE, "o11", update({ title: "x".repeat(201) }), "invalid_title")
  c.op(objects, "thread.update: a control character in the title", ALICE, "o11", update({ title: "a\u0007" }), "invalid_title")
  c.op(objects, "thread.update: an outsider is refused before the root", EVE, "o11", update({ title: "x" }, "msg_nope"), "not_participant")
  c.op(objects, "thread.update: title the root again", ALICE, "o12", update({ title: "Ship 1.0" }), "commit")
  c.op(objects, "thread.update: an edit of the root keeps the thread object", ALICE, "o13", { kind: "message.edit", message_id: top.id, parts: parts("root, edited") }, "commit")
  c.op(objects, "thread.update: retract the root", ALICE, "o14", { kind: "message.retract", message_id: top.id }, "commit")
  c.op(objects, "thread.update: a retracted root may still be resolved", MUX, "o15", update({ status: "resolved" }), "commit")

  // Agent budget: the head's counters (agent_text_streak, last_agent_text_at), no row window.
  const budget = new CoreHost()
  budget.send(ALICE, "h1", "go")
  for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
    budget.advance(10_000)
    c.op(budget, `budget: agent turn ${turn + 1} of ${MAX_AGENT_TURNS}`, MUX, `m${turn}`, send(`m${turn}`, parts(`turn ${turn}`)), "commit")
  }
  budget.advance(10_000)
  c.op(budget, "budget: one agent turn over the budget", MUX, "m9", send("m9", parts("again")), "agent_budget")
  c.op(budget, "budget: a work card is never limited", MUX, "w1", send("w1", [{ type: "work", session: "s", status: "done" }]), "commit")
  c.op(budget, "budget: humans are never limited", ALICE, "h2", send("h2", parts("next")), "commit")
  c.op(budget, "budget: an agent after a human message", MUX, "m10", send("m10", parts("ok")), "commit")
  budget.advance(1_999)
  c.op(budget, "budget: within the 2 s gap", MUX, "m11", send("m11", parts("fast")), "agent_rate")
  c.op(budget, "budget: malformed parts report invalid_parts first", MUX, "m11", send("m11", []), "invalid_parts")
  budget.advance(1)
  c.op(budget, "budget: at the gap", MUX, "m11", send("m11", parts("now")), "commit")

  // The gap's free first round: with two agents, both answer a person's text at once; the third
  // agent text since that person waits the gap (agent-to-agent traffic stays spaced).
  const round = new CoreHost(createdHead({ ...base, participants: [human(ALICE), agent(MUX), agent("agent_two")] }))
  round.send(ALICE, "h1", "status?")
  c.op(round, "gap round: the first agent answers the person", MUX, "r1", send("r1", parts("fine")), "commit")
  round.advance(50)
  c.op(round, "gap round: the second agent answers within the gap", "agent_two", "r2", send("r2", parts("also fine")), "commit")
  round.advance(50)
  c.op(round, "gap round: a third agent text within the gap is refused", MUX, "r3", send("r3", parts("re")), "agent_rate")
  round.advance(1_950)
  c.op(round, "gap round: at the gap", MUX, "r3", send("r3", parts("re")), "commit")

  // The work-card bypass: text-less work cards between agent texts must not reset or hide the count.
  const cards = new CoreHost()
  cards.send(ALICE, "h1", "go")
  for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
    cards.advance(10_000)
    c.op(cards, `loop guard: agent text ${turn + 1} of ${MAX_AGENT_TURNS} between work cards`, MUX, `t${turn}`, send(`t${turn}`, parts(`turn ${turn}`)), "commit")
    c.op(cards, `loop guard: work card ${turn + 1}`, MUX, `w${turn}`, send(`w${turn}`, [{ type: "work", session: "s", status: "running" }]), "commit")
  }
  cards.advance(10_000)
  c.op(cards, "loop guard: one agent text over the budget after work cards is refused", MUX, "t9", send("t9", parts("again")), "agent_budget")
  // link_preview parts (cmux-conversation link_preview.rs): the shape rules, and a commit with every field.
  const links = new CoreHost()
  const image = { hash: "f".repeat(64), mime_type: "image/webp", byte_count: 512_000 }
  const link = (over: Record<string, unknown>) => ({ type: "link_preview", url: "https://example.com/a", ...over }) as never
  c.op(links, "link preview: a non-http scheme", ALICE, "l0", send("l0", [link({ url: "javascript:alert(1)" })]), "invalid_parts")
  c.op(links, "link preview: user info in the authority", ALICE, "l0", send("l0", [link({ url: "https://user@example.com" })]), "invalid_parts")
  c.op(links, "link preview: an empty host", ALICE, "l0", send("l0", [link({ url: "https:///a" })]), "invalid_parts")
  c.op(links, "link preview: a URL over 2048 bytes", ALICE, "l0", send("l0", [link({ url: `https://example.com/${"é".repeat(1015)}` })]), "invalid_parts")
  c.op(links, "link preview: a 301-character title", ALICE, "l0", send("l0", [link({ title: "x".repeat(301) })]), "invalid_parts")
  c.op(links, "link preview: a site with a control character", ALICE, "l0", send("l0", [link({ site: "a\tb" })]), "invalid_parts")
  c.op(links, "link preview: a PNG image", ALICE, "l0", send("l0", [link({ image: { ...image, mime_type: "image/png" } })]), "invalid_parts")
  c.op(links, "link preview: an image over 512000 bytes", ALICE, "l0", send("l0", [link({ image: { ...image, byte_count: 512_001 } })]), "invalid_parts")
  c.op(links, "link preview: every field", ALICE, "l1", send("l1", [text("look"), link({ url: "HTTPS://Example.com/a?b#c", title: "é".repeat(300), site: "example.com", image })]), "commit")
  c.op(links, "link preview: only the URL", ALICE, "l2", send("l2", [link({})]), "commit")
  c.op(links, "link preview: a title of 200 emoji (300 code points at most, not UTF-16 units)", ALICE, "l3", send("l3", [link({ title: "\u{1F600}".repeat(200), site: "\u{1F600}".repeat(200) })]), "commit")
  c.op(links, "link preview: null title, site and image are absent", ALICE, "l4", send("l4", [link({ title: null, site: null, image: null })]), "commit")
  c.op(links, "an unknown part type is refused", ALICE, "l5", send("l5", [text("x"), { type: "future_part", anything: [1, 2] } as never]), "invalid_parts")
  // A link preview is an agent turn like text: link-only messages cannot bypass the loop guard.
  const linkTurns = new CoreHost()
  linkTurns.send(ALICE, "h1", "go")
  for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
    linkTurns.advance(10_000)
    c.op(linkTurns, `loop guard: agent link preview ${turn + 1} of ${MAX_AGENT_TURNS}`, MUX, `p${turn}`, send(`p${turn}`, [link({ url: `https://example.com/${turn}` })]), "commit")
  }
  linkTurns.advance(10_000)
  c.op(linkTurns, "loop guard: one agent link preview over the budget is refused", MUX, "p9", send("p9", [link({})]), "agent_budget")

  // attachment parts (cmux-conversation attachments.rs, home-core attachments.ts): the shape rules both
  // owners apply to a send or an edit. Each owner also checks the part against its own record of the
  // hash (local: conversation-attachment-upload; cloud: the upload intent), outside the reducer.
  const files = new CoreHost()
  const sha = (ch: string) => ch.repeat(64)
  const photo = (over: Record<string, unknown> = {}) =>
    ({ type: "attachment", hash: sha("a"), name: "screen.png", mime_type: "image/png", byte_count: 2_400_000, width: 2880, height: 1800, ...over }) as never
  const clip = (over: Record<string, unknown> = {}) =>
    ({ type: "attachment", hash: sha("b"), name: "run.mp4", mime_type: "video/mp4", byte_count: 18_000_000, width: 1920, height: 1080, duration_ms: 42_000, ...over }) as never
  const jpeg = (ch: string, byte_count: number) => ({ hash: sha(ch), mime_type: "image/jpeg", byte_count })
  c.op(files, "attachment: an image with its preview", ALICE, "f1", send("f1", [photo({ preview: jpeg("c", 512_000) })]), "commit")
  c.op(files, "attachment: a video with its poster and a caption", ALICE, "f2", send("f2", [text("the run"), clip({ poster: { ...jpeg("d", 2_000_000), mime_type: "image/webp" } })]), "commit")
  c.op(files, "attachment: four images and a PDF in one message", ALICE, "f3", send("f3", [photo(), photo({ hash: sha("e"), name: "b.jpg", mime_type: "image/jpeg" }), photo({ hash: sha("f"), name: "c.gif", mime_type: "image/gif" }), photo({ hash: sha("1"), name: "d.webp", mime_type: "image/webp" }), { type: "attachment", hash: sha("2"), name: "spec.pdf", mime_type: "application/pdf", byte_count: 90_000 } as never]), "commit")
  c.op(files, "attachment: 100000000 bytes fit", ALICE, "f4", send("f4", [clip({ byte_count: 100_000_000 })]), "commit")
  c.op(files, "attachment: an agent's attachment-only message is not a turn", MUX, "f5", send("f5", [clip({ hash: sha("3") })]), "commit")
  c.op(files, "attachment: arbitrarily large byte count is accepted", ALICE, "f4-large", send("f4-large", [clip({ byte_count: 100_000_001 })]), "commit")
  c.op(files, "attachment: an SVG is never on the allow list", ALICE, "f0", send("f0", [photo({ name: "logo.svg", mime_type: "image/svg+xml" })]), "invalid_parts")
  c.op(files, "attachment: an HTML page goes as text under its own name", ALICE, "f6", send("f6", [{ type: "attachment", hash: sha("4"), name: "index.html", mime_type: "text/plain", byte_count: 1_200 } as never]), "commit")
  c.op(files, "attachment: any binary goes as a generic file under any name", ALICE, "f7", send("f7", [{ type: "attachment", hash: sha("5"), name: "setup.exe", mime_type: "application/octet-stream", byte_count: 4_096 } as never]), "commit")
  c.op(files, "attachment: an HTML type is never sent as its own type", ALICE, "f0", send("f0", [photo({ name: "index.html", mime_type: "text/html" })]), "invalid_parts")
  c.op(files, "attachment: an upper-case type", ALICE, "f0", send("f0", [photo({ mime_type: "IMAGE/PNG" })]), "invalid_parts")
  c.op(files, "attachment: a hash that is not 64 lowercase hex digits", ALICE, "f0", send("f0", [photo({ hash: "A".repeat(64) })]), "invalid_parts")
  c.op(files, "attachment: a name with a path separator", ALICE, "f0", send("f0", [photo({ name: "../x.png" })]), "invalid_parts")
  c.op(files, "attachment: a 256-character name", ALICE, "f0", send("f0", [photo({ name: `${"n".repeat(252)}.png` })]), "invalid_parts")
  c.op(files, "attachment: zero bytes", ALICE, "f0", send("f0", [photo({ byte_count: 0 })]), "invalid_parts")
  c.op(files, "attachment: a zero width", ALICE, "f0", send("f0", [photo({ width: 0 })]), "invalid_parts")
  c.op(files, "attachment: a poster on an image", ALICE, "f0", send("f0", [photo({ poster: jpeg("c", 1_000) })]), "invalid_parts")
  c.op(files, "attachment: a preview on a video", ALICE, "f0", send("f0", [clip({ preview: jpeg("c", 1_000) })]), "invalid_parts")
  c.op(files, "attachment: a PNG poster", ALICE, "f0", send("f0", [clip({ poster: { ...jpeg("c", 1_000), mime_type: "image/png" } })]), "invalid_parts")
  c.op(files, "attachment: a poster over 2000000 bytes", ALICE, "f0", send("f0", [clip({ poster: jpeg("c", 2_000_001) })]), "invalid_parts")
  c.op(files, "attachment: a preview over 512000 bytes", ALICE, "f0", send("f0", [photo({ preview: jpeg("c", 512_001) })]), "invalid_parts")
  const firstPhoto = files.messages[0]!
  c.op(files, "attachment: an edit may swap the file", ALICE, "f6", { kind: "message.edit", message_id: firstPhoto.id, parts: [text("better"), photo({ hash: sha("4") })] }, "commit")

  threadBudgetCases(c, send, parts)
  questionCases(c)
}

/**
 * The loop guard per thread: two Chiefs (agents) answer each other in a thread; each thread
 * (the replies of one root, or the top level) has its own budget of MAX_AGENT_TURNS agent
 * texts after the last person's text in that thread. Chiefs in two threads do not spend each
 * other's budget; a person's text resets its own thread only; an agent's text never resets it,
 * a Chief's reply to another Chief's question included.
 */
const threadBudgetCases = (
  c: Corpus,
  send: (key: string, p: Array<Part>, reply_to?: { message_id: string; part_index: number }, thread_root?: string) => Op,
  parts: (...values: Array<string>) => Array<Part>
): void => {
  const ALICE = "user_local"
  const RELEASE = "agent_release"
  const INFRA = "agent_infra"
  const made = create({
    id: "conv_01J0000000000000000THREADS",
    actor: ALICE,
    title: "ops",
    participants: [human(ALICE), agent(RELEASE), agent(INFRA)],
    now: NOW
  })
  if (!made.ok) throw new Error(made.code)
  const host = new CoreHost(made.head)
  const rootA = host.send(ALICE, "ra", "the runner is down")
  host.advance(10_000)
  const rootB = host.send(ALICE, "rb", "the cache is full")
  const inA = (key: string) => send(key, parts(key), { message_id: rootA.id, part_index: 0 }, rootA.id)
  const inB = (key: string) => send(key, parts(key), { message_id: rootB.id, part_index: 0 }, rootB.id)
  const chiefs = [RELEASE, INFRA]
  for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
    host.advance(10_000)
    c.op(host, `thread budget: Chief reply ${turn + 1} of ${MAX_AGENT_TURNS} in thread A`, chiefs[turn % 2]!, `a${turn}`, inA(`a${turn}`), "commit")
  }
  host.advance(10_000)
  c.op(host, "thread budget: the next Chief reply in thread A is refused", RELEASE, "a9", inA("a9"), "agent_budget")
  c.op(host, "thread budget: a Chief in thread B has its own budget", INFRA, "b0", inB("b0"), "commit")
  host.advance(10_000)
  c.op(host, "thread budget: the top level has its own budget", RELEASE, "t0", send("t0", parts("summary")), "commit")
  host.advance(10_000)
  c.op(host, "thread budget: a person's text in thread B does not reset thread A", ALICE, "pb", inB("pb"), "commit")
  c.op(host, "thread budget: thread A is still spent", INFRA, "a10", inA("a10"), "agent_budget")
  c.op(host, "thread budget: a person's text in thread A resets it", ALICE, "pa", inA("pa"), "commit")
  host.advance(10_000)
  c.op(host, "thread budget: a Chief may answer in thread A again", INFRA, "a11", inA("a11"), "commit")
  // reply_to alone joins the parent's thread, for the count too.
  const a11 = host.messages.find((m) => m.client_msg_id === "a11")!
  const replyOnly = (key: string) => send(key, parts(key), { message_id: a11.id, part_index: 0 })
  host.advance(10_000)
  c.op(host, "thread budget: a Chief's reply_to-only reply joins thread A and counts", RELEASE, "a12", replyOnly("a12"), "commit")
  c.op(host, "thread budget: a person's reply_to-only reply joins thread A and resets it", ALICE, "pa2", replyOnly("pa2"), "commit")

  // A Chief's reply to another Chief's question is an agent turn: it never resets the streak.
  const asked = new CoreHost(made.head)
  const rootQ = asked.send(ALICE, "rq", "who takes the release?")
  const inQ = (key: string, p: Array<Part>) => send(key, p, { message_id: rootQ.id, part_index: 0 }, rootQ.id)
  const question = questionPart()
  asked.advance(10_000)
  c.op(asked, "thread budget: a Chief asks a question in the thread", RELEASE, "q1", inQ("q1", [question]), "commit")
  for (let turn = 1; turn < MAX_AGENT_TURNS; turn++) {
    asked.advance(10_000)
    c.op(asked, `thread budget: Chief text ${turn + 1} of ${MAX_AGENT_TURNS} after the question`, turn % 2 === 1 ? INFRA : RELEASE, `q${turn + 1}`, inQ(`q${turn + 1}`, parts("yes, take it")), "commit")
  }
  asked.advance(10_000)
  c.op(asked, "thread budget: a Chief's answers to a Chief's question did not reset it", RELEASE, "q9", inQ("q9", parts("ok")), "agent_budget")
  const pending = asked.messages.find((m) => m.client_msg_id === "q1")!.id
  c.op(asked, "thread budget: another Chief may not answer the question part", INFRA, "qa",
    ({ kind: "question.answer", message_id: pending, part_index: 0, answer: { selections: { q0: { option_ids: ["keys"] } } } }) as never, "human_only")
  c.op(asked, "thread budget: a person's answer resets the question's thread", ALICE, "qp",
    ({ kind: "question.answer", message_id: pending, part_index: 0, answer: { selections: { q0: { option_ids: ["keys"] } } } }) as never, "commit")
  asked.advance(10_000)
  c.op(asked, "thread budget: after the person's answer a Chief may go on", RELEASE, "q10", inQ("q10", parts("taking it")), "commit")
}
