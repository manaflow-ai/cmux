import { describe, expect, it } from "vitest"
import { makeConversationDomain, type ConversationParams, type ConversationState } from "../src/conversation/domain.ts"
import type { Principal } from "../src/conversation/engine-types.ts"
import { rowKind, wakesFor } from "../src/conversation/fanout.ts"
import type { HumanReach } from "../src/conversation/reach.ts"
import type { ConversationHead, Message } from "../src/conversation/types.ts"
import { DomainHost } from "./support/harness.ts"

/**
 * A Chief's conversation shared with teammates (cmux#25569). The owner adds a person only with a
 * shared team (the Worker's reach facts), the Chief answers every person there, and each person's
 * inbox row says whose Chief it is: `chief` for its owner, `group` for a teammate.
 */
const OWNER = "user_owner"
const MATE = "user_mate"
const FRIEND = "user_friend"
const CHIEF = "agent_01ARZ3NDEKTSV4RRFFQ69G5FAV"
const SYSTEM: Principal = { kind: "system", identity: "system:user" }

const reach = (user: string, facts: Partial<HumanReach>): HumanReach => ({ user, display_name: user, shared_team: false, connected: false, allow_requests_from: "teams", ...facts })
const owner = (facts: ReadonlyArray<HumanReach>): Principal => ({ kind: "session", identity: OWNER, user: OWNER, display_name: "Owner", home_reach: facts })

const chiefConversation = () => {
  const host = new DomainHost<ConversationState, ConversationParams>(makeConversationDomain())
  const made = host.run(SYSTEM, "conversation.create", {
    id: "conv_CHIEFMAIN",
    kind: "chief",
    owner: OWNER,
    title: "Chief",
    participants: [
      { id: OWNER, kind: "human", display_name: "Owner" },
      { id: CHIEF, kind: "agent", agent_class: "mux", owner_user: OWNER, display_name: "Chief" }
    ]
  } as ConversationParams, "create")
  if (!made.ok) throw new Error(`create: ${made.code}`)
  return host
}
const head = (host: DomainHost<ConversationState, ConversationParams>) => host.state as ConversationHead
const add = (who: string) => ({ participant: { id: who, kind: "human", display_name: "x" } }) as unknown as ConversationParams

describe("sharing a Chief's conversation", () => {
  it("the owner adds a teammate of a shared team, not a connection outside the team", () => {
    const host = chiefConversation()
    const facts = [reach(MATE, { shared_team: true, display_name: "Mate" }), reach(FRIEND, { connected: true })]
    expect(host.run(owner(facts), "participants.add", add(FRIEND), "friend")).toMatchObject({ ok: false, code: "not_reachable" })
    expect(host.run(owner(facts), "participants.add", add(MATE), "mate")).toMatchObject({ ok: true })
    // The trusted name from the team directory, not the caller's.
    expect(head(host).participants.find((p) => p.id === MATE)).toMatchObject({ display_name: "Mate", role: "member" })
    // The teammate sees what comes next, not the owner's earlier talk with the Chief.
    expect(head(host).settings?.history_visible).toBe("since_join")
  })

  it("a teammate never adds anyone, before any reach fact is read", () => {
    const host = chiefConversation()
    host.run(owner([reach(MATE, { shared_team: true })]), "participants.add", add(MATE), "mate")
    const mate: Principal = { kind: "session", identity: MATE, user: MATE, display_name: "Mate", home_reach: [reach(FRIEND, { shared_team: true })] }
    expect(host.run(mate, "participants.add", add(FRIEND), "friend")).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("the Chief answers every person in its conversation, and only a mention under mentions", () => {
    const host = chiefConversation()
    host.run(owner([reach(MATE, { shared_team: true })]), "participants.add", add(MATE), "mate")
    const shared = head(host)
    const said = { id: "msg_1", conversation: shared.id, seq: shared.last_seq + 1, author: MATE, parts: [{ type: "text", text: "status?" }] } as unknown as Message
    expect(wakesFor(shared, said, null).map((w) => [w.agent, w.reason])).toEqual([[CHIEF, "dm"]])
    expect(wakesFor({ ...shared, settings: { ...shared.settings, wake_policy: "mentions" } } as ConversationHead, said, null)).toEqual([])
  })

  it("the owner's row is the Chief; the teammate's row is a group", () => {
    const host = chiefConversation()
    host.run(owner([reach(MATE, { shared_team: true })]), "participants.add", add(MATE), "mate")
    expect(rowKind(head(host), OWNER)).toBe("chief")
    expect(rowKind(head(host), MATE)).toBe("group")
    const bumps = host.outbox.filter((item) => item.kind === "inbox.bump").map((item) => item.payload as { user: string; kind: string })
    expect(bumps.filter((b) => b.user === MATE).map((b) => b.kind)).toContain("group")
    expect(bumps.filter((b) => b.user === OWNER).every((b) => b.kind === "chief")).toBe(true)
  })
})
