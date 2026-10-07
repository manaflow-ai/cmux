import { describe, expect, it } from "vitest"
import {
  conversationDomain,
  defaultParticipantPolicy,
  dmConversationId,
  makeConversationDomain,
  NOT_REACHABLE,
  reachDecision,
  type ConversationParams,
  type ConversationState,
  type HumanReach,
  type Principal
} from "../src/conversation/index.ts"
import { DEFAULT_HOME_SETTINGS, reduceHomeSettings } from "../src/user/index.ts"
import { agent, DomainHost, human } from "./support/harness.ts"
import { ALICE, BOB, CAROL } from "./support/cloud.ts"

/**
 * The human reach rule (home-messaging.md sections 4.1 and 16): a human may be put into a
 * conversation by someone who shares a team with them or is already connected to them, and the
 * target's `allow_requests_from` (anyone|teams|nobody, 16.7) narrows that. The Worker resolves the facts into
 * `principal.home_reach`; the reducer only reads them. Every refusal is `not_reachable`, the
 * same answer as for an unknown account.
 */
const reach = (user: string, extra: Partial<HumanReach> = {}): HumanReach => ({
  user,
  display_name: user === BOB ? "Bob" : "Carol",
  shared_team: false,
  connected: false,
  allow_requests_from: "anyone",
  ...extra
})
const session = (user: string, name: string, home_reach?: ReadonlyArray<HumanReach>): Principal => ({
  identity: `${user}:s`,
  user,
  kind: "session",
  display_name: name,
  ...(home_reach ? { home_reach } : {})
})

describe("human reach decision", () => {
  it("needs a shared team or a connection; allow_requests_from narrows; a block always refuses", () => {
    const refused = { ok: false, code: NOT_REACHABLE }
    expect(reachDecision(undefined)).toEqual(refused)
    expect(reachDecision(reach(BOB))).toEqual(refused)
    expect(reachDecision(reach(BOB, { shared_team: true }))).toEqual({ ok: true, display_name: "Bob" })
    expect(reachDecision(reach(BOB, { connected: true }))).toEqual({ ok: true, display_name: "Bob" })
    expect(reachDecision(reach(BOB, { shared_team: true, allow_requests_from: "teams" }))).toMatchObject({ ok: true })
    // A connected contact may add the target under every value except nobody (16.3), also with no shared team.
    expect(reachDecision(reach(BOB, { connected: true, allow_requests_from: "teams" }))).toEqual({ ok: true, display_name: "Bob" })
    expect(reachDecision(reach(BOB, { connected: true, shared_team: false, allow_requests_from: "anyone" }))).toEqual({ ok: true, display_name: "Bob" })
    expect(reachDecision(reach(BOB, { connected: true, allow_requests_from: "nobody" }))).toEqual(refused)
    // teams without a shared team or a connection: refused.
    expect(reachDecision(reach(BOB, { allow_requests_from: "teams" }))).toEqual(refused)
    // nobody: no new reach, whatever the links.
    expect(reachDecision(reach(BOB, { shared_team: true, connected: true, allow_requests_from: "nobody" }))).toEqual(refused)
    // Interim (16.10): "anyone" without a link is still refused until message requests exist.
    expect(reachDecision(reach(BOB, { allow_requests_from: "anyone" }))).toEqual(refused)
    expect(reachDecision(reach(BOB, { shared_team: true, connected: true, blocked: true }))).toEqual(refused)
    // A name that cleans to nothing falls back; it never comes from the caller.
    expect(reachDecision(reach(BOB, { shared_team: true, display_name: "\u0000" }))).toEqual({ ok: true, display_name: "Member" })
  })
})

describe("conversation Domain with Worker-resolved reach", () => {
  const host = () => new DomainHost<ConversationState, ConversationParams>(conversationDomain)
  const group = (participants: Array<unknown>) => ({ id: "conv_R", kind: "group", title: "Plans", participants })

  it("a group with two humans who share a team; the name comes from the reach facts", () => {
    const h = host()
    const r = h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true })]), "conversation.create", group([human(ALICE, "Alice"), human(BOB, "Mallory")]), "c1")
    expect(r).toMatchObject({ ok: true })
    expect(h.state?.participants.map((p) => [p.id, p.display_name])).toEqual([
      [ALICE, "Alice"],
      [BOB, "Bob"]
    ])
  })

  it("a stranger, an unknown account and a refusal by setting get the same answer", () => {
    const facts = [reach(CAROL, { connected: true, allow_requests_from: "nobody" })]
    expect(host().run(session(ALICE, "Alice", facts), "conversation.create", group([human(ALICE), human(CAROL)]), "c1")).toMatchObject({ ok: false, code: NOT_REACHABLE })
    expect(host().run(session(ALICE, "Alice", facts), "conversation.create", group([human(ALICE), human("user_nobody")]), "c2")).toMatchObject({ ok: false, code: NOT_REACHABLE })
    expect(host().run(session(ALICE, "Alice", []), "conversation.create", group([human(ALICE), human(BOB)]), "c3")).toMatchObject({ ok: false, code: NOT_REACHABLE })
  })

  it("without reach facts (local and self-hosted owners) the old rule stays: only the caller and known participants", () => {
    expect(host().run(session(ALICE, "Alice"), "conversation.create", group([human(ALICE), human(BOB)]), "c1")).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("dm.open with a user id follows the same rule", () => {
    const params = { id: dmConversationId(ALICE, BOB), participants: [human(ALICE, "Alice"), human(BOB, BOB)] }
    expect(host().run(session(ALICE, "Alice", [reach(BOB, { allow_requests_from: "anyone" })]), "dm.open", params, "d1")).toMatchObject({ ok: false, code: NOT_REACHABLE })
    const h = host()
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true })]), "dm.open", params, "d2")).toMatchObject({ ok: true })
    expect(h.state?.participants.find((p) => p.id === BOB)?.display_name).toBe("Bob")
  })

  it("participants.add of a human checks the adder's facts", () => {
    const h = host()
    expect(h.run(session(ALICE, "Alice", []), "conversation.create", group([human(ALICE, "Alice")]), "c1")).toMatchObject({ ok: true })
    expect(h.run(session(ALICE, "Alice", [reach(BOB)]), "participants.add", { participant: human(BOB) }, "p1")).toMatchObject({ ok: false, code: NOT_REACHABLE })
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true, allow_requests_from: "nobody" })]), "participants.add", { participant: human(BOB) }, "p2")).toMatchObject({
      ok: false,
      code: NOT_REACHABLE
    })
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { connected: true })]), "participants.add", { participant: human(BOB) }, "p3")).toMatchObject({ ok: true })
    expect(h.state?.participants.find((p) => p.id === BOB)).toMatchObject({ display_name: "Bob", added_by: ALICE })
  })
})

describe("a chief acting under its owner's reach (CHIEF-DONE autonomy rule)", () => {
  // As the ConversationDO injects it: the owner's chief is admitted, humans follow the default rule.
  const domain = makeConversationDomain({
    participantPolicy: (principal, participant, head) =>
      participant.kind === "agent" && principal.user === ALICE ? { ok: true, owner_user: ALICE, display_name: "Chief" } : defaultParticipantPolicy(principal, participant, head)
  })
  const host = () => new DomainHost<ConversationState, ConversationParams>(domain)
  const chief = (home_reach?: ReadonlyArray<HumanReach>): Principal => ({ identity: "inst_c", kind: "agent", agent: "agent_chief", user: ALICE, ...(home_reach ? { home_reach } : {}) })

  it("adds a human from the owner's facts, and is refused like any caller without a link", () => {
    const h = host()
    expect(h.run(session(ALICE, "Alice", []), "conversation.create", { id: "conv_R", kind: "group", title: "Plans", participants: [human(ALICE, "Alice"), agent("agent_chief", ALICE)] }, "c1")).toMatchObject({ ok: true })
    expect(h.run(chief([reach(BOB, { shared_team: true })]), "participants.add", { participant: human(BOB) }, "p1")).toMatchObject({ ok: true })
    expect(h.state?.participants.find((p) => p.id === BOB)).toMatchObject({ display_name: "Bob", added_by: "agent_chief" })
    expect(h.run(chief([]), "participants.add", { participant: human(CAROL) }, "p2")).toMatchObject({ ok: false, code: NOT_REACHABLE })
  })
})

describe("a departed human (review: the stored record is not a reach link)", () => {
  const host = () => new DomainHost<ConversationState, ConversationParams>(conversationDomain)
  const group = (participants: Array<unknown>) => ({ id: "conv_R", kind: "group", title: "Plans", participants })
  /** Alice and Bob share a team; Alice makes a group with Bob, and Bob leaves it. */
  const departed = () => {
    const h = host()
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true })]), "conversation.create", group([human(ALICE, "Alice"), human(BOB)]), "c1")).toMatchObject({ ok: true })
    expect(h.run(session(BOB, "Bob", []), "participants.remove", { participant: BOB }, "r1")).toMatchObject({ ok: true })
    expect(h.state?.participants.find((p) => p.id === BOB)?.left_at).toBeDefined()
    return h
  }

  it("a member with no link to the departed human cannot add them back", () => {
    const h = departed()
    expect(h.run(session(ALICE, "Alice", []), "participants.add", { participant: human(BOB) }, "p1")).toMatchObject({ ok: false, code: NOT_REACHABLE })
    // A link the target's setting excludes is refused as well.
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true, allow_requests_from: "nobody" })]), "participants.add", { participant: human(BOB) }, "p2")).toMatchObject({
      ok: false,
      code: NOT_REACHABLE
    })
    expect(h.state?.participants.find((p) => p.id === BOB)?.left_at).toBeDefined()
  })

  it("a member who shares a team with them may add them back; the stored name stays", () => {
    const h = departed()
    expect(h.run(session(ALICE, "Alice", [reach(BOB, { shared_team: true, display_name: "Robert" })]), "participants.add", { participant: human(BOB, "Mallory") }, "p1")).toMatchObject({ ok: true })
    const bob = h.state?.participants.find((p) => p.id === BOB)
    expect(bob?.left_at).toBeUndefined()
    expect(bob?.display_name).toBe("Bob")
  })

  it("without reach facts (local and self-hosted owners) a departed human rejoins as before", () => {
    const h = departed()
    expect(h.run(session(ALICE, "Alice"), "participants.add", { participant: human(BOB) }, "p1")).toMatchObject({ ok: true })
  })
})

describe("home.settings.set (UserDO, section 4.2)", () => {
  it("defaults, partial updates, and refuses unknown values", () => {
    expect(DEFAULT_HOME_SETTINGS).toEqual({ discoverable_by_email: false, discoverable_by_phone: false, allow_requests_from: "anyone", email_requests: true })
    expect(reduceHomeSettings(undefined, { allow_requests_from: "teams" })).toEqual({ ok: true, settings: { ...DEFAULT_HOME_SETTINGS, allow_requests_from: "teams" } })
    expect(reduceHomeSettings(undefined, { allow_requests_from: "nobody" })).toEqual({ ok: true, settings: { ...DEFAULT_HOME_SETTINGS, allow_requests_from: "nobody" } })
    // The pre-16.7 names are gone.
    expect(reduceHomeSettings(undefined, { allow_requests_from: "contacts" })).toEqual({ ok: false, code: "invalid_settings" })
    expect(reduceHomeSettings(undefined, { allow_dm_from: "teams" })).toEqual({ ok: false, code: "invalid_settings" })
    const current = { ...DEFAULT_HOME_SETTINGS, allow_requests_from: "teams" as const }
    expect(reduceHomeSettings(current, { discoverable_by_email: true })).toEqual({ ok: true, settings: { ...current, discoverable_by_email: true } })
    expect(reduceHomeSettings(current, { allow_requests_from: "everyone" })).toEqual({ ok: false, code: "invalid_settings" })
    expect(reduceHomeSettings(current, { discoverable_by_phone: "yes" })).toEqual({ ok: false, code: "invalid_settings" })
    expect(reduceHomeSettings(current, {})).toEqual({ ok: false, code: "invalid_settings" })
    expect(reduceHomeSettings(current, null)).toEqual({ ok: false, code: "invalid_settings" })
    // R2 (2026-10-02): message-request email, on by default; the recipient can turn it off.
    expect(reduceHomeSettings(current, { email_requests: false })).toEqual({ ok: true, settings: { ...current, email_requests: false } })
    expect(reduceHomeSettings(current, { email_requests: "off" })).toEqual({ ok: false, code: "invalid_settings" })
    // Settings stored before email_requests existed read it as the default.
    const legacy = { discoverable_by_email: true, discoverable_by_phone: false, allow_requests_from: "teams" } as unknown as typeof current
    expect(reduceHomeSettings(legacy, { discoverable_by_phone: true })).toEqual({ ok: true, settings: { discoverable_by_email: true, discoverable_by_phone: true, allow_requests_from: "teams", email_requests: true } })
    // A value stored under the old name (never deployed) is dropped; the new field reads as the default.
    const renamed = { discoverable_by_email: false, discoverable_by_phone: false, allow_dm_from: "contacts", email_requests: true } as unknown as typeof current
    expect(reduceHomeSettings(renamed, { email_requests: false })).toEqual({ ok: true, settings: { ...DEFAULT_HOME_SETTINGS, email_requests: false } })
  })
})
