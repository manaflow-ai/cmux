import { create } from "../src/conversation/create.ts"
import type { Op, Part } from "../src/conversation/types.ts"
import { agent, CoreHost, human, NOW, text } from "../test/support/harness.ts"
import type { Corpus } from "./generate.ts"

const ALICE = "user_local"
const MUX = "agent_mux"
const PHONE = "remote_inst_1"
const EVE = "user_eve"

/**
 * A question as an agent harness sends it: no `allows_other`, `state` or preview `format`, so
 * the commit records the defaults (true, pending, monospace) every owner must fill in. Every
 * case here must deserialize in the Rust crate (its runner parses the whole file first), so
 * shapes serde refuses (an unknown harness, a wrong field type) stay in the unit tests.
 */
export const questionPart = (extra: Record<string, unknown> = {}, item: Record<string, unknown> = {}): Part =>
  ({
    type: "question",
    harness: "chief",
    session: "sess_mux",
    permission: "perm_1",
    agent: "Chief",
    items: [
      {
        id: "q0",
        header: "Auth",
        prompt: "Which auth method?",
        options: [
          { id: "oauth", label: "OAuth", detail: "Delegated" },
          { id: "keys", label: "API keys", preview: { text: "KEY=..." } }
        ],
        ...item
      }
    ],
    ...extra
  }) as never

/** `question` parts and `question.answer` (Rust question.rs): local heads, a paired device. */
export const questionCases = (c: Corpus): void => {
  const created = create({
    id: "conv_01J0000000000000000QUESTN",
    actor: ALICE,
    title: "mux",
    participants: [human(ALICE, "Lawrence"), agent(MUX), { ...human(PHONE, "Lawrence's iPhone"), person: ALICE }],
    now: NOW
  })
  if (!created.ok) throw new Error(created.code)
  const host = new CoreHost(created.head)
  const send = (key: string, parts: ReadonlyArray<Part>): Op => ({ kind: "message.send", client_msg_id: key, parts })
  const answer = (message_id: string, selections: unknown, part_index = 0): Op =>
    ({ kind: "question.answer", message_id, part_index, answer: { selections } }) as never
  const last = () => host.messages.at(-1)!.id
  // A question counts as an agent turn (loop guard): agent sends here are 10 s apart.
  const mux = (name: string, key: string, op: Op, expect: string) => {
    host.advance(10_000)
    c.op(host, name, MUX, key, op, expect)
  }

  mux("question: an agent posts a question", "q1", send("q1", [questionPart()]), "commit")
  const asked = last()
  c.op(host, "question: a human may not post a question", ALICE, "q2", send("q2", [questionPart()]), "invalid_parts")
  c.op(host, "question: a paired device may not post a question", PHONE, "q2", send("q2", [questionPart()]), "invalid_parts")
  mux("question: a sent question must be pending", "q2", send("q2", [questionPart({ state: { kind: "cancelled" } })]), "invalid_parts")
  mux("question: a sent question may not arrive answered", "q2", send("q2", [questionPart({ state: { kind: "answered", answer: { selections: { q0: { option_ids: ["keys"] } } } } })]), "invalid_parts")
  mux("question: an item without options must allow Other", "q2", send("q2", [questionPart({}, { options: [], allows_other: false })]), "invalid_parts")
  mux("question: an item without options allows Other by default", "q2", send("q2", [questionPart({}, { options: [] })]), "commit")
  mux("question: duplicate option ids", "q3", send("q3", [questionPart({}, { options: [{ id: "a", label: "A" }, { id: "a", label: "B" }] })]), "invalid_parts")
  mux("question: no items", "q3", send("q3", [questionPart({ items: [] })]), "invalid_parts")
  mux("question: a blank prompt", "q3", send("q3", [questionPart({}, { prompt: " \n" })]), "invalid_parts")

  c.op(host, "question.answer: an outsider", EVE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "not_participant")
  c.op(host, "question.answer: unknown message", ALICE, "a1", answer("msg_missing", { q0: { option_ids: ["keys"] } }), "unknown_message")
  c.op(host, "question.answer: part index past the parts", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }, 1), "invalid_part_index")
  mux("question.answer: an agent never answers", "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "human_only")
  c.op(host, "question.answer: a missing item", ALICE, "a1", answer(asked, {}), "invalid_answer")
  c.op(host, "question.answer: an empty selection", ALICE, "a1", answer(asked, { q0: {} }), "invalid_answer")
  c.op(host, "question.answer: an unknown option", ALICE, "a1", answer(asked, { q0: { option_ids: ["nope"] } }), "invalid_answer")
  c.op(host, "question.answer: two options on a single select", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys", "oauth"] } }), "invalid_answer")
  c.op(host, "question.answer: an option and Other on a single select", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"], other: "x" } }), "invalid_answer")
  c.op(host, "question.answer: a repeated option", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys", "keys"] } }), "invalid_answer")
  c.op(host, "question.answer: an unknown item", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] }, q9: { option_ids: ["keys"] } }), "invalid_answer")
  c.op(host, "question.answer: a human answers, the owner stamps the respondent", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "commit")
  c.op(host, "question.answer: a second answer", ALICE, "a2", answer(asked, { q0: { option_ids: ["oauth"] } }), "question_closed")

  mux("question: a closed question", "q4", send("q4", [questionPart({}, { allows_other: false })]), "commit")
  const closed = last()
  c.op(host, "question.answer: Other where the item does not allow it", ALICE, "a3", answer(closed, { q0: { other: "mTLS" } }), "invalid_answer")
  c.op(host, "question.answer: blank Other where the item does not allow it counts as none", ALICE, "a3", answer(closed, { q0: { option_ids: ["oauth"], other: "  " } }), "commit")

  mux("question: for the paired device", "q5", send("q5", [questionPart()]), "commit")
  c.op(host, "question.answer: a paired device answers as its person, Other trimmed", PHONE, "a4", answer(last(), { q0: { other: "  mTLS " } }), "commit")

  mux("question: multi select", "q6", send("q6", [questionPart({}, { multi_select: true })]), "commit")
  c.op(host, "question.answer: multi select keeps the item's option order", ALICE, "a5", answer(last(), { q0: { option_ids: ["keys", "oauth"], other: "SSO" } }), "commit")

  mux("question: to edit", "q7", send("q7", [text("Before we go on:"), questionPart()]), "commit")
  const edited = last()
  const edit = (parts: ReadonlyArray<Part>): Op => ({ kind: "message.edit", message_id: edited, parts })
  mux("question edit: the author rewords a question", "e1", edit([text("Before we go on:"), questionPart({}, { prompt: "Something else?" })]), "invalid_parts")
  mux("question edit: a forged answered state", "e1", edit([text("Before we go on:"), questionPart({ state: { kind: "answered", answer: { selections: { q0: { option_ids: ["keys"] } } } } })]), "invalid_parts")
  mux("question edit: dropping the question", "e1", edit([text("gone")]), "invalid_parts")
  mux("question edit: moving the question", "e1", edit([questionPart(), text("Before we go on:")]), "invalid_parts")
  mux("question edit: the author cancels, and rewords the text", "e1", edit([text("Never mind:"), questionPart({ state: { kind: "cancelled" } })]), "commit")
  c.op(host, "question.answer: a cancelled question", ALICE, "a6", answer(edited, { q0: { option_ids: ["keys"] } }, 1), "question_closed")
  c.op(host, "question.answer: a text part", ALICE, "a6", answer(edited, { q0: { option_ids: ["keys"] } }, 0), "invalid_part_index")
  mux("question edit: an answered question may not be cancelled", "e2", { kind: "message.edit", message_id: asked, parts: [questionPart({ state: { kind: "cancelled" } })] }, "invalid_parts")

  questionBudgetCases(c)
}

/** A question is an agent turn: it counts toward the loop guard and the gap, and a person's answer is a human turn. */
const questionBudgetCases = (c: Corpus): void => {
  const send = (key: string, parts: ReadonlyArray<Part>): Op => ({ kind: "message.send", client_msg_id: key, parts })
  const guard = new CoreHost()
  guard.send(ALICE, "h1", "go")
  for (let turn = 0; turn < 4; turn++) {
    guard.advance(10_000)
    c.op(guard, `question budget: agent question ${turn + 1} of 4`, MUX, `q${turn}`, send(`q${turn}`, [questionPart()]), "commit")
  }
  guard.advance(10_000)
  c.op(guard, "question budget: a fifth agent question", MUX, "q9", send("q9", [questionPart()]), "agent_budget")
  c.op(guard, "question budget: a fifth agent text after four questions", MUX, "t9", send("t9", [text("again")]), "agent_budget")
  const pending = guard.messages.at(-1)!.id
  c.op(guard, "question budget: the person answers", "user_local", "a1",
    ({ kind: "question.answer", message_id: pending, part_index: 0, answer: { selections: { q0: { option_ids: ["keys"] } } } }) as never, "commit")
  c.op(guard, "question budget: an answer is a human turn, the agent may go on", MUX, "t10", send("t10", [text("thanks")]), "commit")
  guard.advance(1_999)
  c.op(guard, "question budget: a question within the 2 s gap", MUX, "q10", send("q10", [questionPart()]), "agent_rate")
}
