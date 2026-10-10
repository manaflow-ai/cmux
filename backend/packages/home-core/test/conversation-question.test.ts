import { describe, expect, it } from "vitest"
import { questionPart } from "../conformance/question-cases.ts"
import {
  create,
  MAX_QUESTION_ITEMS,
  MAX_QUESTION_LABEL_BYTES,
  MAX_QUESTION_OPTIONS,
  MAX_QUESTION_PREVIEW_BYTES,
  MAX_QUESTION_TEXT_BYTES,
  messageText,
  type Message,
  type Op,
  type Part
} from "../src/conversation/index.ts"
import { agent, CoreHost, human, NOW } from "./support/harness.ts"

/** The Rust crate's question_tests.rs, against the TypeScript core. */
const ALICE = "user_local"
const MUX = "agent_mux"
const PHONE = "remote_inst1"

const host = (): CoreHost => {
  const result = create({
    id: "conv_Q",
    actor: ALICE,
    title: "mux",
    participants: [human(ALICE, "Lawrence"), agent(MUX), { ...human(PHONE, "Lawrence's iPhone"), person: ALICE }],
    now: NOW
  })
  if (!result.ok) throw new Error(result.code)
  return new CoreHost(result.head)
}

const send = (parts: ReadonlyArray<unknown>): Op => ({ kind: "message.send", client_msg_id: "k1", parts: parts as Array<Part> })
const code = (result: { ok: boolean; code?: string }) => (result.ok ? "ok" : result.code)
const sendCode = (actor: string, part: unknown) => code(host().run(actor, "k1", send([part])))
const answerOp = (message_id: string, selections: unknown, part_index: unknown = 0): Op =>
  ({ kind: "question.answer", message_id, part_index, answer: { selections } }) as never

const posted = (item: Record<string, unknown> = {}): { h: CoreHost; message: Message } => {
  const h = host()
  const result = h.run(MUX, "k1", send([questionPart({}, item)]))
  if (!result.ok) throw new Error(result.code)
  return { h, message: result.commit.message! }
}
const stateOf = (message: Message) => (message.parts[0] as unknown as { state: Record<string, any> }).state

describe("question parts", () => {
  it("fills the Rust defaults and strips unknown fields", () => {
    const { message } = posted()
    const part = JSON.parse(JSON.stringify(message.parts[0]))
    expect(part).toEqual({
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
            { id: "keys", label: "API keys", preview: { text: "KEY=...", format: "monospace" } }
          ],
          multi_select: false,
          allows_other: true
        }
      ],
      state: { kind: "pending" }
    })
    const lean = posted({ options: [], header: null, extra: 1 }).message.parts[0]
    expect(JSON.parse(JSON.stringify(lean)).items[0]).toEqual({ id: "q0", prompt: "Which auth method?", options: [], multi_select: false, allows_other: true })
  })

  it("only an agent posts a question, and only pending", () => {
    expect(sendCode(ALICE, questionPart())).toBe("invalid_parts")
    expect(sendCode(PHONE, questionPart())).toBe("invalid_parts")
    expect(sendCode(MUX, questionPart())).toBe("ok")
    expect(sendCode(MUX, questionPart({ state: { kind: "cancelled" } }))).toBe("invalid_parts")
  })

  it("refuses shapes serde refuses and enforces the limits", () => {
    const option = (id: string) => ({ id, label: id })
    const item = (id: string) => ({ id, prompt: "p", options: [option("a")] })
    const bad: Array<unknown> = [
      questionPart({ harness: "other" }),
      questionPart({ session: " " }),
      questionPart({ permission: "" }),
      questionPart({ agent: "\t" }),
      questionPart({ items: "x" }),
      questionPart({ state: null }),
      questionPart({ state: { kind: "done" } }),
      questionPart({}, { multi_select: "yes" }),
      questionPart({}, { options: null }),
      questionPart({}, { prompt: "x".repeat(MAX_QUESTION_TEXT_BYTES + 1) }),
      questionPart({}, { header: "x".repeat(MAX_QUESTION_LABEL_BYTES + 1) }),
      questionPart({}, { id: "" }),
      questionPart({}, { options: [{ id: "a", label: "é".repeat(MAX_QUESTION_LABEL_BYTES / 2 + 1) }] }),
      questionPart({}, { options: [{ id: "a", label: "A", detail: "x".repeat(MAX_QUESTION_TEXT_BYTES + 1) }] }),
      questionPart({}, { options: [{ id: "a", label: "A", preview: { text: "x".repeat(MAX_QUESTION_PREVIEW_BYTES + 1) } }] }),
      questionPart({}, { options: [{ id: "a", label: "A", preview: { text: "x", format: "html" } }] }),
      questionPart({}, { options: Array.from({ length: MAX_QUESTION_OPTIONS + 1 }, (_, i) => option(`o${i}`)) }),
      questionPart({ items: Array.from({ length: MAX_QUESTION_ITEMS + 1 }, (_, i) => item(`q${i}`)) }),
      questionPart({ items: [item("q"), item("q")] })
    ]
    for (const part of bad) expect(sendCode(MUX, part), JSON.stringify(part).slice(0, 120)).toBe("invalid_parts")
    const good: Array<unknown> = [
      questionPart({ items: Array.from({ length: MAX_QUESTION_ITEMS }, (_, i) => item(`q${i}`)) }),
      questionPart({}, { options: Array.from({ length: MAX_QUESTION_OPTIONS }, (_, i) => option(`o${i}`)) }),
      questionPart({}, { prompt: "x".repeat(MAX_QUESTION_TEXT_BYTES) }),
      questionPart({}, { options: [{ id: "a", label: "A", detail: "", preview: { text: "", format: "markdown" } }] }),
      questionPart({ permission: null, agent: null })
    ]
    for (const part of good) expect(sendCode(MUX, part), JSON.stringify(part).slice(0, 120)).toBe("ok")
  })

  it("blank means Rust str::trim: U+0085 is whitespace, U+FEFF is not", () => {
    expect(sendCode(MUX, questionPart({}, { prompt: "\u0085" }))).toBe("invalid_parts")
    expect(sendCode(MUX, questionPart({}, { prompt: "﻿" }))).toBe("ok")
  })

  it("search text is the first item's prompt", () => {
    expect(messageText(posted().message)).toBe("Which auth method?")
  })
})

describe("question.answer", () => {
  it("a person answers once and the owner stamps the respondent", () => {
    const { h, message } = posted()
    const result = h.run(ALICE, "a1", answerOp(message.id, { q0: { option_ids: ["keys"] } }))
    expect(code(result)).toBe("ok")
    if (!result.ok) return
    expect(result.commit.change.kind).toBe("message-updated")
    expect(stateOf(result.commit.message!)).toEqual({
      kind: "answered",
      answer: { selections: { q0: { option_ids: ["keys"] } }, respondent: { participant: ALICE, display_name: "Lawrence", remote: false }, answered_at: NOW }
    })
    expect(code(h.run(ALICE, "a2", answerOp(message.id, { q0: { option_ids: ["oauth"] } })))).toBe("question_closed")
  })

  it("a paired device answers as its person and names the device", () => {
    const { h, message } = posted()
    const result = h.run(PHONE, "a1", answerOp(message.id, { q0: { other: "  mTLS " } }))
    expect(code(result)).toBe("ok")
    if (!result.ok) return
    expect(stateOf(result.commit.message!).answer).toEqual({
      selections: { q0: { option_ids: [], other: "mTLS" } },
      respondent: { participant: ALICE, display_name: "Lawrence's iPhone", device: "Lawrence's iPhone", remote: true },
      answered_at: NOW
    })
  })

  it("an agent never answers", () => {
    const { h, message } = posted()
    expect(code(h.run(MUX, "a1", answerOp(message.id, { q0: { option_ids: ["keys"] } })))).toBe("human_only")
  })

  it("refuses invalid answers", () => {
    const { h, message } = posted()
    for (const selections of [
      {},
      { q0: {} },
      { q0: { option_ids: ["nope"] } },
      { q0: { option_ids: ["keys", "oauth"] } },
      { q0: { option_ids: ["keys"], other: "x" } },
      { q0: { option_ids: ["keys", "keys"] } },
      { q0: { option_ids: ["keys"] }, q9: { option_ids: ["keys"] } },
      { constructor: { option_ids: ["keys"] } },
      { q0: { option_ids: ["keys"], other: "x".repeat(MAX_QUESTION_TEXT_BYTES + 1) } },
      null,
      { q0: { option_ids: "keys" } },
      { q0: { option_ids: ["keys"], other: 3 } }
    ]) {
      expect(code(h.run(ALICE, "a1", answerOp(message.id, selections))), JSON.stringify(selections)).toBe("invalid_answer")
    }
    expect(code(h.run(ALICE, "a1", answerOp(message.id, { q0: { option_ids: ["keys"] } }, -1)))).toBe("invalid_part_index")
  })

  it("multi select keeps the item's option order", () => {
    const { h, message } = posted({ multi_select: true })
    const result = h.run(ALICE, "a1", answerOp(message.id, { q0: { option_ids: ["keys", "oauth"], other: "SSO" } }))
    expect(code(result)).toBe("ok")
    if (result.ok) expect(stateOf(result.commit.message!).answer.selections).toEqual({ q0: { option_ids: ["oauth", "keys"], other: "SSO" } })
  })

  it("the author may only cancel a pending question by edit", () => {
    const { h, message } = posted()
    const edit = (part: unknown): Op => ({ kind: "message.edit", message_id: message.id, parts: [part as Part] })
    expect(code(h.run(MUX, "e1", edit(questionPart({}, { prompt: "Something else?" }))))).toBe("invalid_parts")
    expect(code(h.run(MUX, "e1", edit(questionPart({ state: { kind: "answered", answer: { selections: { q0: { option_ids: ["keys"] } } } } }))))).toBe("invalid_parts")
    expect(code(h.run(MUX, "e1", edit({ type: "text", text: "gone" })))).toBe("invalid_parts")
    // Defaults written out are the same content.
    expect(code(h.run(MUX, "e1", edit(questionPart({ state: { kind: "pending" } }, { allows_other: true, multi_select: false }))))).toBe("ok")
    const cancelled = h.run(MUX, "e2", edit(questionPart({ state: { kind: "cancelled" } })))
    expect(code(cancelled)).toBe("ok")
    if (cancelled.ok) expect(stateOf(cancelled.commit.message!)).toEqual({ kind: "cancelled" })
    expect(code(h.run(MUX, "e3", edit(questionPart())))).toBe("invalid_parts")
  })

  it("answering a non-question part is refused", () => {
    const h = host()
    const message = h.send(MUX, "k1", "hi")
    expect(code(h.run(ALICE, "a1", answerOp(message.id, { q0: { option_ids: ["keys"] } })))).toBe("invalid_part_index")
  })
})
