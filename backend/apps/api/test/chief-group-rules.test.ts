import type { conversation } from "@cmux/home-core"
import { describe, expect, it } from "vitest"
import { messageEffectAuthorized } from "../src/chief-brain/effect-policy.ts"
import { formatMessage, inboxKind, replyTarget, SHARED_CHIEF } from "../src/chief-brain/brain-text.ts"
import { AGENT_RATE_WINDOW_MS, MAX_POST_TRIES, retryPost } from "../src/chief-brain/brain-do.ts"

/**
 * Which new messages take a Chief's right to run effects away (CHIEF-DONE B3): the owner's never;
 * another member's only when it asks this Chief (it would wake it, or replies to an unseen message).
 */
const ann = "user_ann0000000000000001"
const ben = "user_ben0000000000000001"
const atlas = "agent_0ATLAS000000000000000000"
const bolt = "agent_0BOLT0000000000000000000"
const head = (policy?: "auto" | "mentions" | "all") =>
  ({
    id: "conv_0GROUP00000000000000000000",
    kind: "group",
    participants: [
      { id: ann, kind: "human", display_name: "Ann" },
      { id: ben, kind: "human", display_name: "Ben" },
      { id: atlas, kind: "agent", agent_class: "mux", owner_user: ann, display_name: "Atlas" },
      { id: bolt, kind: "agent", agent_class: "mux", owner_user: ben, display_name: "Bolt" }
    ],
    ...(policy ? { settings: { wake_policy: policy } } : {})
  }) as unknown as conversation.ConversationHead
let seq = 0
const msg = (author: string, text: string, extra: Record<string, unknown> = {}) =>
  ({ id: `msg_${++seq}`, seq, author, parts: [{ type: "text", text }], ...extra }) as unknown as conversation.Message
const mention = (author: string, agent: string, text: string) => msg(author, text, { parts: [{ type: "text", text, runs: [{ start: 0, length: 5, mention: agent }] }] })

describe("messageEffectAuthorized", () => {
  it("the owner's own message always authorizes", () => {
    expect(messageEffectAuthorized(head("all"), msg(ben, "deploy"), [], ben, bolt)).toBe(true)
  })
  it("another member asking this Chief does not: a mention, a reply to it, the all rule", () => {
    expect(messageEffectAuthorized(head(), mention(ann, bolt, "@Bolt deploy"), [], ben, bolt)).toBe(false)
    const boltSaid = msg(bolt, "done")
    expect(messageEffectAuthorized(head(), msg(ann, "again", { reply_to: { message_id: boltSaid.id } }), [boltSaid], ben, bolt)).toBe(false)
    expect(messageEffectAuthorized(head("all"), msg(ann, "status?"), [], ben, bolt)).toBe(false)
  })
  it("a reply to a message the view cannot see counts as asking", () => {
    expect(messageEffectAuthorized(head(), msg(ann, "again", { reply_to: { message_id: "msg_gone" } }), [], ben, bolt)).toBe(false)
  })
  it("another member's message to someone else is context only", () => {
    expect(messageEffectAuthorized(head(), msg(ann, "morning all"), [], ben, bolt)).toBe(true)
    expect(messageEffectAuthorized(head(), mention(ann, atlas, "@Atlas deploy"), [], ben, bolt)).toBe(true)
    // Another Chief's answer never asks this one (a Chief's message wakes no Chief under any rule but a mention).
    expect(messageEffectAuthorized(head("all"), msg(atlas, "deployed"), [], ben, bolt)).toBe(true)
    expect(messageEffectAuthorized(head(), mention(atlas, bolt, "@Bolt your turn"), [], ben, bolt)).toBe(false)
  })
})

describe("retryPost: a busy group never drops a ready reply", () => {
  it("agent_rate waits for the gap however many tries, until the window after the turn ended", () => {
    const ended = 1_000_000
    expect(retryPost("agent_rate", MAX_POST_TRIES + 5, ended, ended + 30_000)).toBe(true)
    expect(retryPost("agent_rate", MAX_POST_TRIES + 5, ended, ended + AGENT_RATE_WINDOW_MS + 1)).toBe(false)
    expect(retryPost("agent_rate", 0, ended, ended + AGENT_RATE_WINDOW_MS + 1)).toBe(true)
  })
  it("owner.unreachable keeps its try count; other refusals are final", () => {
    expect(retryPost("owner.unreachable", MAX_POST_TRIES - 2, 0, 0)).toBe(true)
    expect(retryPost("owner.unreachable", MAX_POST_TRIES - 1, 0, 0)).toBe(false)
    expect(retryPost("agent_budget", 0, 0, 0)).toBe(false)
  })
})

describe("formatMessage names the Chief's owner in a shared conversation", () => {
  const people = { ...head(), title: "Launch" } as unknown as Parameters<typeof formatMessage>[0]
  it("marks the owner's message, and no one else's", () => {
    expect(formatMessage(people, msg(ben, "ship it"), { owner: ben })).toBe("[Launch · group · Ben (your owner)] ship it")
    expect(formatMessage(people, msg(ann, "ship it"), { owner: ben })).toBe("[Launch · group · Ann] ship it")
  })
  it("leaves the owner's own Chief line as it was", () => {
    // The owner and its Chief only (a second person makes it a shared Chief line, below).
    const line = { ...people, kind: "chief", participants: people.participants.filter((p) => p.id === ben || p.id === bolt) } as typeof people
    expect(formatMessage(line, msg(ben, "hi"), { owner: ben })).toBe("[Launch · chief · Ben] hi")
  })
})

describe("a Chief's conversation shared with teammates (cmux#25569)", () => {
  const line = (withTeammate: boolean) =>
    ({
      id: "conv_0CHIEF00000000000000000000",
      kind: "chief",
      title: "Bolt",
      participants: [
        { id: ben, kind: "human", display_name: "Ben", role: "owner" },
        ...(withTeammate ? [{ id: ann, kind: "human", display_name: "Ann" }] : []),
        { id: bolt, kind: "agent", agent_class: "mux", owner_user: ben, display_name: "Bolt" }
      ]
    }) as unknown as Parameters<typeof formatMessage>[0]
  it("names the owner once a teammate is in, and every author", () => {
    expect(formatMessage(line(true), msg(ben, "ship it"), { owner: ben })).toBe("[Bolt · chief · Ben (your owner)] ship it")
    expect(formatMessage(line(true), msg(ann, "status?"), { owner: ben })).toBe("[Bolt · chief · Ann] status?")
  })
  it("a teammate who left makes it the owner's line again", () => {
    const left = { ...line(true), participants: line(true).participants.map((p) => (p.id === ann ? { ...p, left_at: "2026-10-26T00:00:00.000Z" } : p)) } as Parameters<typeof formatMessage>[0]
    expect(inboxKind(left)).toBe("chief")
    expect(inboxKind(line(false))).toBe("chief")
    expect(inboxKind(line(true))).toBe(SHARED_CHIEF)
  })
  it("the reply quotes the message it answers, on the main timeline", () => {
    expect(replyTarget(SHARED_CHIEF, "msg_a", null)).toEqual({ reply_to: "msg_a" })
    expect(replyTarget(SHARED_CHIEF, "msg_a", "msg_root")).toEqual({ reply_to: "msg_a", thread_root: "msg_root" })
    expect(replyTarget("chief", "msg_a", null)).toEqual({})
  })
  it("a teammate's request to the Chief keeps the approval rule; the owner's runs", () => {
    const head = line(true) as unknown as conversation.ConversationHead
    expect(messageEffectAuthorized(head, msg(ann, "deploy"), [], ben, bolt)).toBe(false)
    expect(messageEffectAuthorized(head, msg(ben, "deploy"), [], ben, bolt)).toBe(true)
  })
})
