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

  c.op(host, "question: an agent posts a question", MUX, "q1", send("q1", [questionPart()]), "commit")
  const asked = last()
  c.op(host, "question: a human may not post a question", ALICE, "q2", send("q2", [questionPart()]), "invalid_parts")
  c.op(host, "question: a paired device may not post a question", PHONE, "q2", send("q2", [questionPart()]), "invalid_parts")
  c.op(host, "question: a sent question must be pending", MUX, "q2", send("q2", [questionPart({ state: { kind: "cancelled" } })]), "invalid_parts")
  c.op(host, "question: a sent question may not arrive answered", MUX, "q2", send("q2", [questionPart({ state: { kind: "answered", answer: { selections: { q0: { option_ids: ["keys"] } } } } })]), "invalid_parts")
  c.op(host, "question: an item without options must allow Other", MUX, "q2", send("q2", [questionPart({}, { options: [], allows_other: false })]), "invalid_parts")
  c.op(host, "question: an item without options allows Other by default", MUX, "q2", send("q2", [questionPart({}, { options: [] })]), "commit")
  c.op(host, "question: duplicate option ids", MUX, "q3", send("q3", [questionPart({}, { options: [{ id: "a", label: "A" }, { id: "a", label: "B" }] })]), "invalid_parts")
  c.op(host, "question: no items", MUX, "q3", send("q3", [questionPart({ items: [] })]), "invalid_parts")
  c.op(host, "question: a blank prompt", MUX, "q3", send("q3", [questionPart({}, { prompt: " \n" })]), "invalid_parts")

  c.op(host, "question.answer: an outsider", EVE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "not_participant")
  c.op(host, "question.answer: unknown message", ALICE, "a1", answer("msg_missing", { q0: { option_ids: ["keys"] } }), "unknown_message")
  c.op(host, "question.answer: part index past the parts", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }, 1), "invalid_part_index")
  c.op(host, "question.answer: an agent never answers", MUX, "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "human_only")
  c.op(host, "question.answer: a missing item", ALICE, "a1", answer(asked, {}), "invalid_answer")
  c.op(host, "question.answer: an empty selection", ALICE, "a1", answer(asked, { q0: {} }), "invalid_answer")
  c.op(host, "question.answer: an unknown option", ALICE, "a1", answer(asked, { q0: { option_ids: ["nope"] } }), "invalid_answer")
  c.op(host, "question.answer: two options on a single select", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys", "oauth"] } }), "invalid_answer")
  c.op(host, "question.answer: an option and Other on a single select", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"], other: "x" } }), "invalid_answer")
  c.op(host, "question.answer: a repeated option", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys", "keys"] } }), "invalid_answer")
  c.op(host, "question.answer: an unknown item", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] }, q9: { option_ids: ["keys"] } }), "invalid_answer")
  c.op(host, "question.answer: a human answers, the owner stamps the respondent", ALICE, "a1", answer(asked, { q0: { option_ids: ["keys"] } }), "commit")
  c.op(host, "question.answer: a second answer", ALICE, "a2", answer(asked, { q0: { option_ids: ["oauth"] } }), "question_closed")

  c.op(host, "question: a closed question", MUX, "q4", send("q4", [questionPart({}, { allows_other: false })]), "commit")
  const closed = last()
  c.op(host, "question.answer: Other where the item does not allow it", ALICE, "a3", answer(closed, { q0: { other: "mTLS" } }), "invalid_answer")
  c.op(host, "question.answer: blank Other where the item does not allow it counts as none", ALICE, "a3", answer(closed, { q0: { option_ids: ["oauth"], other: "  " } }), "commit")

  c.op(host, "question: for the paired device", MUX, "q5", send("q5", [questionPart()]), "commit")
  c.op(host, "question.answer: a paired device answers as its person, Other trimmed", PHONE, "a4", answer(last(), { q0: { other: "  mTLS " } }), "commit")

  c.op(host, "question: multi select", MUX, "q6", send("q6", [questionPart({}, { multi_select: true })]), "commit")
  c.op(host, "question.answer: multi select keeps the item's option order", ALICE, "a5", answer(last(), { q0: { option_ids: ["keys", "oauth"], other: "SSO" } }), "commit")

  c.op(host, "question: to edit", MUX, "q7", send("q7", [text("Before we go on:"), questionPart()]), "commit")
  const edited = last()
  const edit = (parts: ReadonlyArray<Part>): Op => ({ kind: "message.edit", message_id: edited, parts })
  c.op(host, "question edit: the author rewords a question", MUX, "e1", edit([text("Before we go on:"), questionPart({}, { prompt: "Something else?" })]), "invalid_parts")
  c.op(host, "question edit: a forged answered state", MUX, "e1", edit([text("Before we go on:"), questionPart({ state: { kind: "answered", answer: { selections: { q0: { option_ids: ["keys"] } } } } })]), "invalid_parts")
  c.op(host, "question edit: dropping the question", MUX, "e1", edit([text("gone")]), "invalid_parts")
  c.op(host, "question edit: moving the question", MUX, "e1", edit([questionPart(), text("Before we go on:")]), "invalid_parts")
  c.op(host, "question edit: the author cancels, and rewords the text", MUX, "e1", edit([text("Never mind:"), questionPart({ state: { kind: "cancelled" } })]), "commit")
  c.op(host, "question.answer: a cancelled question", ALICE, "a6", answer(edited, { q0: { option_ids: ["keys"] } }, 1), "question_closed")
  c.op(host, "question.answer: a text part", ALICE, "a6", answer(edited, { q0: { option_ids: ["keys"] } }, 0), "invalid_part_index")
  c.op(host, "question edit: an answered question may not be cancelled", MUX, "e2", { kind: "message.edit", message_id: asked, parts: [questionPart({ state: { kind: "cancelled" } })] }, "invalid_parts")
}
