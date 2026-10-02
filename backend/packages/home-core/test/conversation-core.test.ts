import { describe, expect, it } from "vitest"
import {
  apply,
  checkAgentBudget,
  checkTyping,
  create,
  dmConversationId,
  encodeId,
  formatRfc3339Millis,
  LOCAL_REJECT_CODES,
  MAX_AGENT_TURNS,
  MAX_TEXT_BYTES,
  MIN_AGENT_GAP_MS,
  OWNER_LOCAL,
  parseRfc3339Millis,
  type Message,
  type Op,
  type Part,
  type Participant
} from "../src/conversation/index.ts"
import { agent, CoreHost, human, NOW, text } from "./support/harness.ts"

const ALICE = "user_local"
const MUX = "agent_mux"
const EVE = "user_eve"

const code = (result: { ok: boolean; code?: string }) => (result.ok ? "ok" : result.code)
const sendOp = (key: string, parts: Array<Part>, reply_to?: { message_id: string; part_index: number }): Op => ({
  kind: "message.send",
  client_msg_id: key,
  parts,
  ...(reply_to ? { reply_to } : {})
})

describe("conversation core (ports of the Rust crate tests)", () => {
  it("create validates participants and title", () => {
    const head = new CoreHost().head
    expect([head.rev, head.last_seq]).toEqual([1, 0])
    const createWith = (actor: string, title: string, participants: Array<Participant>) => code(create({ id: "conv_X", actor, title, participants, now: NOW }))
    expect(createWith(EVE, "t", [human(ALICE)])).toBe("not_participant")
    expect(createWith(ALICE, "", [human(ALICE)])).toBe("invalid_title")
    expect(createWith(ALICE, "x".repeat(201), [human(ALICE)])).toBe("invalid_title")
    expect(createWith(ALICE, "é".repeat(200), [human(ALICE)])).toBe("ok")
    expect(createWith(ALICE, "t", [])).toBe("invalid_participant")
    expect(createWith(ALICE, "t", [human(ALICE), human(ALICE)])).toBe("duplicate_participant")
    expect(createWith(ALICE, "t", [human(ALICE), { ...human(MUX) }])).toBe("invalid_participant")
    expect(createWith("bob", "t", [human("bob")])).toBe("invalid_participant")
  })

  it("send assigns dense seq and requires a matching client_msg_id", () => {
    const host = new CoreHost()
    const first = host.send(ALICE, "c1", "hi")
    const second = host.send(MUX, "c2", "hello")
    expect([first.seq, second.seq]).toEqual([1, 2])
    expect([host.head.last_seq, host.head.rev]).toEqual([2, 3])
    expect(code(host.run(ALICE, "other", sendOp("c3", [text("x")])))).toBe("invalid_client_msg_id")
    expect(code(host.run(EVE, "c4", sendOp("c4", [text("x")])))).toBe("not_participant")
    expect(host.head.rev).toBe(3)
  })

  it("parts are bounded", () => {
    const host = new CoreHost()
    const bad: Array<Array<Part>> = [
      [],
      Array.from({ length: 17 }, () => text("x")),
      [text("")],
      [text("a".repeat(MAX_TEXT_BYTES)), text("b")],
      [{ type: "text", text: "héllo", runs: [{ start: 3, length: 3 }] }],
      [{ type: "text", text: "hi", runs: [{ start: 0, length: 2, mention: "nobody" }] }],
      [{ type: "work", session: "", status: "running" }]
    ]
    for (const parts of bad) expect(code(host.run(ALICE, "k", sendOp("k", parts)))).toBe("invalid_parts")
    expect(code(host.run(ALICE, "k", sendOp("k", Array.from({ length: 16 }, () => text("x")))))).toBe("ok")
    const edge: Part = {
      type: "text",
      text: "@mux 👋",
      runs: [
        { start: 0, length: 4, mention: MUX },
        { start: 5, length: 2 }
      ]
    }
    expect(code(host.run(ALICE, "k2", sendOp("k2", [edge])))).toBe("ok")
  })

  it("reply_to must name an existing part", () => {
    const host = new CoreHost()
    const first = host.send(ALICE, "c1", "question")
    expect(code(host.run(MUX, "c2", sendOp("c2", [text("answer")], { message_id: "msg_nope", part_index: 0 })))).toBe("unknown_message")
    expect(code(host.run(MUX, "c2", sendOp("c2", [text("answer")], { message_id: first.id, part_index: 1 })))).toBe("invalid_part_index")
    const sent = host.run(MUX, "c2", sendOp("c2", [text("answer")], { message_id: first.id, part_index: 0 }))
    expect(sent.ok && sent.commit.message?.reply_to?.message_id).toBe(first.id)
  })

  it("edit and retract are author only", () => {
    const host = new CoreHost()
    const message = host.send(ALICE, "c1", "draft")
    const edit = (id: string): Op => ({ kind: "message.edit", message_id: id, parts: [text("final")] })
    expect(code(host.run(MUX, "e1", edit(message.id)))).toBe("not_author")
    expect(code(host.run(ALICE, "e1", edit("msg_missing")))).toBe("unknown_message")
    const edited = host.run(ALICE, "e1", edit(message.id))
    expect(edited.ok && edited.commit.change).toMatchObject({ kind: "message-updated", message: { parts: [text("final")], edited_at: NOW } })
    const retract: Op = { kind: "message.retract", message_id: message.id }
    expect(code(host.run(MUX, "r1", retract))).toBe("not_author")
    const retracted = host.run(ALICE, "r1", retract)
    expect(retracted.ok && retracted.commit.message).toMatchObject({ parts: [], retracted_at: NOW })
    expect(code(host.run(ALICE, "r2", retract))).toBe("retracted")
    expect(code(host.run(ALICE, "e2", edit(message.id)))).toBe("retracted")
  })

  it("concurrent reactions from two authors both survive", () => {
    const host = new CoreHost()
    const message = host.send(ALICE, "c1", "ship it?")
    const add = (reaction: Record<string, string>): Op => ({ kind: "reaction.add", message_id: message.id, part_index: 0, reaction: reaction as never })
    expect(code(host.run(ALICE, "a1", add({ tapback: "love" })))).toBe("ok")
    expect(code(host.run(MUX, "a2", add({ tapback: "love" })))).toBe("ok")
    expect(code(host.run(MUX, "a3", add({ tapback: "love" })))).toBe("duplicate_reaction")
    expect(code(host.run(MUX, "a4", add({ emoji: "🎉" })))).toBe("ok")
    expect(host.find(message.id)!.reactions).toHaveLength(3)
    const remove: Op = { kind: "reaction.remove", message_id: message.id, part_index: 0, reaction: { tapback: "love" } }
    expect(code(host.run(ALICE, "d1", remove))).toBe("ok")
    expect(code(host.run(ALICE, "d2", remove))).toBe("unknown_reaction")
    expect(host.find(message.id)!.reactions.map((reaction) => reaction.author)).toEqual([MUX, MUX])
    expect(code(host.run(ALICE, "a5", add({ emoji: "" })))).toBe("invalid_reaction")
    expect(code(host.run(ALICE, "a6", { kind: "reaction.add", message_id: message.id, part_index: 1, reaction: { tapback: "like" } }))).toBe("invalid_part_index")
  })

  it("message changes keep the list order", () => {
    const host = new CoreHost()
    const id = host.send(ALICE, "c1", "hi").id
    host.now = "2026-10-01T13:00:00.000Z"
    const love = { tapback: "love" as const }
    const ops: Array<[string, Op]> = [
      ["a1", { kind: "reaction.add", message_id: id, part_index: 0, reaction: love }],
      ["e1", { kind: "message.edit", message_id: id, parts: [text("edited")] }],
      ["d1", { kind: "reaction.remove", message_id: id, part_index: 0, reaction: love }],
      ["a2", { kind: "reaction.add", message_id: id, part_index: 0, reaction: love }],
      ["r1", { kind: "message.retract", message_id: id }]
    ]
    for (const [key, op] of ops) {
      expect(code(host.run(ALICE, key, op))).toBe("ok")
      expect(host.head.updated_at, key).toBe(NOW)
    }
    expect(code(host.run(ALICE, "d2", { kind: "reaction.remove", message_id: id, part_index: 0, reaction: love }))).toBe("retracted")
    expect(code(host.run(ALICE, "t1", { kind: "title.set", title: "renamed" }))).toBe("ok")
    expect(host.head.updated_at).toBe("2026-10-01T13:00:00.000Z")
  })

  it("read cursor is monotonic and bounded", () => {
    const host = new CoreHost()
    host.send(ALICE, "c1", "one")
    host.send(ALICE, "c2", "two")
    expect(code(host.run(MUX, "r0", { kind: "read_cursor.set", seq: 3 }))).toBe("cursor_out_of_range")
    const commit = host.run(MUX, "r1", { kind: "read_cursor.set", seq: 2 })
    expect(commit.ok && commit.commit.change).toEqual({ kind: "read-cursor", participant: MUX, seq: 2 })
    expect(host.head.read_cursors[MUX]).toBe(2)
    expect(code(host.run(MUX, "r2", { kind: "read_cursor.set", seq: 1 }))).toBe("cursor_regression")
    expect(code(host.run(EVE, "r3", { kind: "read_cursor.set", seq: 1 }))).toBe("not_participant")
  })

  it("participants and title emit a summary", () => {
    const host = new CoreHost()
    const last = host.send(ALICE, "c1", "hi")
    const added = host.run(ALICE, "p1", { kind: "participants.add", participant: human(EVE) })
    if (!added.ok || added.commit.change.kind !== "conversation") throw new Error("summary change")
    expect(added.commit.change.conversation.participants).toHaveLength(3)
    expect(added.commit.change.conversation.owner).toBe(OWNER_LOCAL)
    expect(added.commit.change.conversation.last_message?.id).toBe(last.id)
    expect(code(host.run(ALICE, "p2", { kind: "participants.add", participant: human(EVE) }))).toBe("duplicate_participant")
    expect(code(host.run(EVE, "t1", { kind: "title.set", title: "" }))).toBe("invalid_title")
    expect(code(host.run(EVE, "t2", { kind: "title.set", title: "Team" }))).toBe("ok")
    expect(host.head.title).toBe("Team")
    expect(checkTyping(host.head, EVE)).toBeNull()
    expect(checkTyping(host.head, "user_zed")?.code).toBe("not_participant")
  })

  it("wire shapes match the contract", () => {
    const host = new CoreHost()
    const message = host.send(ALICE, "c1", "hi")
    const json = JSON.parse(JSON.stringify({ kind: "message-updated", message }))
    expect(json.message.parts).toEqual([{ type: "text", text: "hi" }])
    expect(json.message.reactions).toEqual([])
    expect("edited_at" in json.message).toBe(false)
    expect(LOCAL_REJECT_CODES).toHaveLength(20)
    expect(LOCAL_REJECT_CODES.slice(0, 7)).toEqual([
      "not_participant",
      "not_author",
      "unknown_message",
      "invalid_parts",
      "idempotency_conflict",
      "cursor_regression",
      "unknown_conversation"
    ])
  })

  it("ids and timestamps are fixed width", () => {
    expect(formatRfc3339Millis(0)).toBe("1970-01-01T00:00:00.000Z")
    expect(formatRfc3339Millis(951_782_400_123)).toBe("2000-02-29T00:00:00.123Z")
    expect(formatRfc3339Millis(1_790_000_000_999)).toBe("2026-09-21T14:13:20.999Z")
    const id = encodeId("conv_", 1_790_000_000_999, new Uint8Array(10).fill(0xff))
    expect(id).toHaveLength(31)
    expect(id.endsWith("ZZZZZZZZZZZZZZZZ")).toBe(true)
    expect(encodeId("msg_", 1, new Uint8Array(10))).toBe("msg_00000000010000000000000000")
    expect(encodeId("msg_", 1, new Uint8Array(10)) < encodeId("msg_", 2, new Uint8Array(10))).toBe(true)
    for (const ms of [0, 1, 999, 86_399_999, 1_790_000_000_123, 4_102_444_800_000]) {
      expect(parseRfc3339Millis(formatRfc3339Millis(ms))).toBe(ms)
      expect(formatRfc3339Millis(ms)).toBe(new Date(ms).toISOString())
    }
    expect(parseRfc3339Millis("2026-10-01 12:00:00.000Z")).toBeNull()
    expect(parseRfc3339Millis("1969-12-31T23:59:59.999Z")).toBeNull()
  })

  it("dm ids are symmetric, prefixed and 26 base32 characters", () => {
    const id = dmConversationId("user_b", "user_a")
    expect(id).toBe(dmConversationId("user_a", "user_b"))
    expect(id).toMatch(/^conv_dm_[0-9A-HJKMNP-TV-Z]{26}$/)
    expect(id).not.toBe(dmConversationId("user_a", "user_c"))
  })
})

describe("agent budget (ports of budget.rs tests)", () => {
  const head = new CoreHost(
    (() => {
      const result = create({ id: "conv_1", actor: ALICE, title: "t", participants: [human(ALICE), agent(MUX), agent("agent_other")], now: NOW })
      if (!result.ok) throw new Error(result.code)
      return result.head
    })()
  ).head
  const base = 1_790_000_000_000
  const message = (seq: number, author: string, atMs: number, parts: Array<Part> = [text("x")]): Message => ({
    id: `msg_${seq}`,
    conversation: "conv_1",
    seq,
    client_msg_id: `c${seq}`,
    author,
    parts,
    created_at: formatRfc3339Millis(atMs),
    reactions: []
  })

  it("limits agents, not humans", () => {
    const newestFirst = [message(1, ALICE, base)]
    for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
      const at = base + 10_000 * (turn + 1)
      expect(checkAgentBudget(head, MUX, [text("x")], newestFirst, at)).toBeNull()
      newestFirst.unshift(message(turn + 2, turn % 2 === 0 ? MUX : "agent_other", at))
    }
    const later = base + 1_000_000
    expect(checkAgentBudget(head, MUX, [text("x")], newestFirst, later)).toBe("agent_budget")
    expect(checkAgentBudget(head, ALICE, [text("x")], newestFirst, later)).toBeNull()
    newestFirst.unshift(message(10, ALICE, later))
    expect(checkAgentBudget(head, MUX, [text("x")], newestFirst, later + 1)).toBeNull()
  })

  it("enforces the gap", () => {
    const recent = [message(2, MUX, base), message(1, ALICE, base - 5_000)]
    expect(checkAgentBudget(head, "agent_other", [text("x")], recent, base + MIN_AGENT_GAP_MS - 1)).toBe("agent_rate")
    expect(checkAgentBudget(head, "agent_other", [text("x")], recent, base + MIN_AGENT_GAP_MS)).toBeNull()
  })

  it("skips work cards and a clock that moved back", () => {
    const card: Array<Part> = [{ type: "work", session: "child", status: "running" }]
    const recent = [message(1, ALICE, base)]
    for (let seq = 2; seq < 8; seq++) recent.unshift(message(seq, MUX, base + seq * 10, card))
    expect(checkAgentBudget(head, MUX, card, recent, base + 100)).toBeNull()
    expect(checkAgentBudget(head, MUX, [text("x")], recent, base + 100)).toBeNull()
    const replied = [message(9, MUX, base + 60_000), message(1, ALICE, base)]
    expect(checkAgentBudget(head, MUX, [text("x")], replied, base + 1_000)).toBeNull()
  })

  it("apply enforces the budget after every other rule when the host passes recent messages", () => {
    const host = new CoreHost()
    host.budget = true
    host.send(ALICE, "h1", "go")
    host.advance(10_000)
    host.send(MUX, "m1", "one")
    expect(code(host.run(MUX, "m2", sendOp("m2", [text("two")])))).toBe("agent_rate")
    // A malformed send reports its own reject first.
    expect(code(host.run(MUX, "m2", sendOp("m2", [])))).toBe("invalid_parts")
    host.advance(MIN_AGENT_GAP_MS)
    expect(code(host.run(MUX, "m2", sendOp("m2", [text("two")])))).toBe("ok")
    expect(apply(host.head, host.request(MUX, "m3", sendOp("m3", [text("x")]), { recent: null })).ok).toBe(true)
  })
})
