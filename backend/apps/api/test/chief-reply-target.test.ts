import { conversation } from "@cmux/home-core"
import { describe, expect, it } from "vitest"
import { answerTarget, ownsRoot, replyTarget, rootOf, SHARED_CHIEF, threadOf } from "../src/chief-brain/brain-text.ts"

/**
 * #25588: where a Cloud Chief's reply goes. A message that answers another without naming a thread
 * (`reply_to` only: an inline reply, a client from before threads, an import) shows in the thread of the
 * message it answers in every Home client. The brain kept only `thread_root`, so in the Chief's line or a
 * DM its answer went to the top level. The reply must also be one the owner takes: a `reply_to` with a
 * `thread_root` is refused unless the root is the answered message's own (home-core apply), so every
 * target here is sent through home-core's `apply` as the Chief.
 */
const CONV = "conv_0CHIEF0000000000000000000"
const ME = "user_local"
const CHIEF = "agent_mux"
const AT = "2026-10-01T12:00:00.000Z"
const head = {
  id: CONV,
  title: "Chief",
  participants: [
    { id: ME, kind: "human", display_name: "Alice" },
    { id: CHIEF, kind: "agent", display_name: "Chief", agent_class: "mux", acp_session: "mux" }
  ],
  last_seq: 4,
  rev: 4,
  created_at: AT,
  updated_at: AT,
  read_cursors: { [ME]: 4, [CHIEF]: 4 },
  agent_text_streak: 0,
  last_agent_text_at: AT
} as unknown as conversation.ConversationHead
const msg = (seq: number, extra: Partial<conversation.Message> = {}): conversation.Message =>
  ({ id: `msg_${seq}`, conversation: CONV, seq, client_msg_id: `k${seq}`, author: ME, parts: [{ type: "text", text: `m${seq}` }], created_at: AT, reactions: [], ...extra }) as conversation.Message
const answers = (id: string) => ({ reply_to: { message_id: id, part_index: 0 } })

// msg_1 top level; msg_2 in its thread; msg_3 answers msg_2 and msg_4 answers msg_1, neither naming a thread.
const messages = [msg(1), msg(2, { ...answers("msg_1"), thread_root: "msg_1" }), msg(3, answers("msg_2")), msg(4, answers("msg_1"))]
const byId = new Map(messages.map((m) => [m.id, m]))

type Target = { reply_to?: string; thread_root?: string }

/** The Chief's answer to `question` as `post` sends it, applied by the owner: the committed message, or the refusal. */
const answer = (kind: string, question: conversation.Message) => commit(replyTarget(kind, question.id, threadOf(question, messages), ownsRoot(question)))

/** `target` sent by the Chief and applied by the owner: the committed message, or the refusal. */
const commit = (target: Target) => {
  const result = conversation.apply(head, {
    actor: CHIEF,
    idempotency_key: "reply",
    op: { kind: "message.send", client_msg_id: "reply", parts: [{ type: "text", text: "answer" }], ...(target.reply_to ? { reply_to: { message_id: target.reply_to, part_index: 0 } } : {}), ...(target.thread_root ? { thread_root: target.thread_root } : {}) } as conversation.Op,
    now: "2026-10-01T12:05:00.000Z",
    new_message_id: "msg_9",
    reply_target: target.reply_to ? byId.get(target.reply_to)! : null,
    thread_target: target.thread_root ? byId.get(target.thread_root)! : null,
    last_message: messages.at(-1)!
  })
  if (!result.ok) return { refused: (result as { code: string }).code }
  const sent = result.commit.message!
  return { reply_to: sent.reply_to?.message_id, thread_root: sent.thread_root }
}

describe("threadOf and rootOf", () => {
  it("is the owner's root, or none at the top level", () => {
    expect(threadOf(byId.get("msg_2")!, messages)).toBe("msg_1")
    expect(threadOf(byId.get("msg_1")!, messages)).toBeNull()
  })

  it("is the answered message's thread for a reply without a root, through a chain of them", () => {
    expect(threadOf(byId.get("msg_3")!, messages)).toBe("msg_1")
    expect(threadOf(byId.get("msg_4")!, messages)).toBe("msg_1")
    expect(threadOf(msg(5, answers("msg_4")), messages)).toBe("msg_1")
  })

  it("is unknown when the chain leaves the loaded messages or loops", () => {
    expect(rootOf("msg_9", messages)).toBeNull()
    expect(rootOf("msg_7", [msg(7, answers("msg_6"))])).toBeNull()
    expect(rootOf("msg_7", [msg(7, answers("msg_8")), msg(8, answers("msg_7"))])).toBeNull()
  })
})

describe("the Chief's reply, as the owner commits it", () => {
  for (const kind of ["chief", "dm", "group"]) {
    it(`${kind}: an answer to a reply that names no thread goes in that thread`, () => {
      expect(answer(kind, byId.get("msg_3")!)).toEqual({ reply_to: undefined, thread_root: "msg_1" })
      expect(answer(kind, byId.get("msg_4")!)).toEqual({ reply_to: undefined, thread_root: "msg_1" })
    })

    it(`${kind}: an answer to a thread reply answers it in its thread`, () => {
      expect(answer(kind, byId.get("msg_2")!)).toEqual({ reply_to: "msg_2", thread_root: "msg_1" })
    })
  }

  it("keeps a top-level question's answer at the top level of the Chief's line and a DM", () => {
    expect(answer("chief", byId.get("msg_1")!)).toEqual({ reply_to: undefined, thread_root: undefined })
    expect(answer("dm", byId.get("msg_1")!)).toEqual({ reply_to: undefined, thread_root: undefined })
  })

  it("a shared Chief chat quotes a top-level question, and answers a reply without a root in its thread", () => {
    expect(answer(SHARED_CHIEF, byId.get("msg_1")!)).toEqual({ reply_to: "msg_1", thread_root: undefined })
    expect(answer(SHARED_CHIEF, byId.get("msg_2")!)).toEqual({ reply_to: "msg_2", thread_root: "msg_1" })
    expect(answer(SHARED_CHIEF, byId.get("msg_3")!)).toEqual({ reply_to: undefined, thread_root: "msg_1" })
  })

  it("threads a channel answer under a top-level question", () => {
    expect(answer("group", byId.get("msg_1")!)).toEqual({ reply_to: "msg_1", thread_root: "msg_1" })
  })

  it("answers a reply whose thread is not loaded without naming a thread, in every kind", () => {
    for (const kind of ["chief", "dm", "group", SHARED_CHIEF]) expect(replyTarget(kind, "msg_7", null, false)).toEqual({ reply_to: "msg_7" })
  })

  it("rows from before own_root keep the old target (the root is the message's own)", () => {
    expect(replyTarget("chief", "msg_2", "msg_1")).toEqual({ reply_to: "msg_2", thread_root: "msg_1" })
  })
})

describe("the opencode host's post with reply_to only (answerTarget), as the owner commits it", () => {
  const post = (kind: string, id: string) => commit(answerTarget(kind, byId.get(id)!, messages))

  it("quotes a top-level message on the main timeline of the Chief's line, a shared Chief line and a DM", () => {
    for (const kind of ["chief", SHARED_CHIEF, "dm"]) expect(post(kind, "msg_1")).toEqual({ reply_to: "msg_1", thread_root: undefined })
  })

  it("threads a channel answer under a top-level message", () => {
    expect(post("group", "msg_1")).toEqual({ reply_to: "msg_1", thread_root: "msg_1" })
  })

  it("answers a thread reply, or a reply without a root, in its thread, in every kind", () => {
    for (const kind of ["chief", SHARED_CHIEF, "dm", "group"]) {
      expect(post(kind, "msg_2")).toEqual({ reply_to: "msg_2", thread_root: "msg_1" })
      expect(post(kind, "msg_3")).toEqual({ reply_to: undefined, thread_root: "msg_1" })
    }
  })
})

describe("ownsRoot", () => {
  it("takes a null thread_root as none, as threadOf does, so the target is one the owner takes", () => {
    const nullRoot = { ...msg(5, answers("msg_2")), thread_root: null } as unknown as conversation.Message
    expect(ownsRoot(nullRoot)).toBe(false)
    expect(replyTarget("chief", nullRoot.id, threadOf(nullRoot, messages), ownsRoot(nullRoot))).toEqual({ thread_root: "msg_1" })
  })
})
