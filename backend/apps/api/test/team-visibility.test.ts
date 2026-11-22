import type { EventFrame, Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { TeamState } from "../src/domains/team.ts"
import * as visibility from "../src/domains/team-visibility.ts"

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const state = {
  team: { id: "team_00000000000000000001", kind: "stack", display_name: "Acme" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "o" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "m" }
  },
  hosts: {},
  policy: { version: 3, values: { "telemetry.level": { value: "off", mode: "enforced" } }, updated_at: 1, updated_by: OWNER },
  policy_history: [{ version: 3, values: {}, changed: ["telemetry.level"], actor: OWNER, at: 1, reason: "secret reason", rollback_of: null }],
  enrollment_tokens: { enr_1: { id: "enr_1", label: "Jamf", token_hash: "x".repeat(43), allowed_domains: ["acme.com"], expires_at: null, created_by: OWNER, created_at: 1, revoked_at: null, uses: 1 } },
  managed_devices: {
    inst_a: { install: "inst_a", user: MEMBER, via: "token", token: "enr_1", at: 1 },
    inst_b: { install: "inst_b", user: OWNER, via: "accept", token: null, at: 1 }
  },
  audit_head: "h",
  audit_count: 4
} as unknown as TeamState

const who = (user: string): Principal => ({ identity: `user:${user}`, user, kind: "session" })
const event = (op: string, user: string): EventFrame => ({ t: "event", stream: "team:t", seq: 1, tx: "t", op, params: {}, actor: who(user), origin: "cli", at: 1 })

describe("TeamDO subscriber view (review MED, decision c)", () => {
  it("members see the policy but not history, tokens, other users' devices or the audit head; admins see all", () => {
    const view = (visibility as { teamSubscriberView?: (s: TeamState, p: Principal) => unknown }).teamSubscriberView
    expect(typeof view).toBe("function")
    const member = view!(state, who(MEMBER)) as Record<string, unknown>
    expect(member.policy).toEqual(state.policy)
    expect(member.policy_history).toBeUndefined()
    expect(member.enrollment_tokens).toBeUndefined()
    expect(member.audit_head).toBeUndefined()
    expect(Object.keys(member.managed_devices as object)).toEqual(["inst_a"])
    expect(view!(state, who(OWNER))).toEqual(state)
  })

  it("enrollment and device events reach admins and the device's own user only", () => {
    const visible = (visibility as { teamEventVisible?: (s: TeamState, e: EventFrame, p: Principal) => boolean }).teamEventVisible
    expect(typeof visible).toBe("function")
    expect(visible!(state, event("team.enrollment_token.create", OWNER), who(MEMBER))).toBe(false)
    expect(visible!(state, event("team.enrollment_token.create", OWNER), who(OWNER))).toBe(true)
    expect(visible!(state, event("team.device.enroll", MEMBER), who(MEMBER))).toBe(true)
    expect(visible!(state, event("team.device.enroll", OWNER), who(MEMBER))).toBe(false)
    expect(visible!(state, event("team.policy.update", OWNER), who(MEMBER))).toBe(true)
  })
})
