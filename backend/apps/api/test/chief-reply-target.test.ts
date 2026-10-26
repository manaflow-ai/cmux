import type { conversation } from "@cmux/home-core"
import { describe, expect, it } from "vitest"
import { replyTarget, rootOf, threadOf } from "../src/chief-brain/brain-text.ts"

/**
 * #25588: where a Cloud Chief's reply goes. A message that answers another without naming a thread
 * (`reply_to` only: an inline reply, or a client from before threads) shows in the thread of the
 * message it answers in every Home client. The brain kept only `thread_root`, so in the Chief's line
 * or a DM its answer went to the top level, outside the thread the question is in.
 */
const msg = (id: string, extra: Partial<conversation.Message> = {}): conversation.Message =>
  ({ id, conversation: "conv_0CHIEF0000000000000000000", seq: Number(id.slice(-1)), author: "user_ann0000000000000001", parts: [{ type: "text", text: id }], created_at: "2026-10-26T12:00:00.000Z", reactions: [], ...extra }) as conversation.Message
const answers = (id: string) => ({ reply_to: { message_id: id, part_index: 0 } })

describe("threadOf", () => {
  const root = msg("msg_1")
  const inThread = msg("msg_2", { ...answers("msg_1"), thread_root: "msg_1" })
  const messages = [root, inThread]

  it("is the owner's root, or none at the top level", () => {
    expect(threadOf(inThread, messages)).toBe("msg_1")
    expect(threadOf(root, messages)).toBeNull()
  })

  it("is the answered message's thread for a reply without a root", () => {
    expect(threadOf(msg("msg_3", answers("msg_2")), messages)).toBe("msg_1")
    expect(threadOf(msg("msg_3", answers("msg_1")), messages)).toBe("msg_1")
  })

  it("is none when the answered message is not loaded (no root is guessed)", () => {
    expect(threadOf(msg("msg_3", answers("msg_9")), messages)).toBeNull()
    expect(rootOf("msg_9", messages)).toBeNull()
  })
})

describe("replyTarget", () => {
  const messages = [msg("msg_1"), msg("msg_2", { ...answers("msg_1"), thread_root: "msg_1" })]

  it("answers an inline reply in the Chief's line in the thread it shows in", () => {
    const question = msg("msg_3", answers("msg_2"))
    expect(replyTarget("chief", question.id, threadOf(question, messages))).toEqual({ reply_to: "msg_3", thread_root: "msg_1" })
    expect(replyTarget("dm", question.id, threadOf(question, messages))).toEqual({ reply_to: "msg_3", thread_root: "msg_1" })
  })

  it("keeps a top-level question's answer at the top level of the Chief's line", () => {
    expect(replyTarget("chief", "msg_1", threadOf(messages[0]!, messages))).toEqual({})
  })

  it("threads a channel answer under the question", () => {
    expect(replyTarget("group", "msg_1", null)).toEqual({ reply_to: "msg_1", thread_root: "msg_1" })
  })
})
