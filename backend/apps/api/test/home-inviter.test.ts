import { describe, expect, it } from "vitest"
import { inviteSender } from "../src/home-routes.ts"

/** The team inviter rule's inviter facts (home-send.ts): a person's own session only, the email only when verified. */
describe("inviteSender", () => {
  const base = { identity: "user_a", user: "user_a", team: "team_a", email: "a@manaflow.ai", email_verified: true }
  it("takes a session's user and verified email", () => {
    expect(inviteSender({ ...base, kind: "session" })).toEqual({ user: "user_a", email: "a@manaflow.ai" })
  })
  it("drops an unverified email", () => {
    expect(inviteSender({ ...base, kind: "session", email_verified: false })).toEqual({ user: "user_a", email: null })
  })
  it("gives nothing for installs, agents and system principals", () => {
    expect(inviteSender({ ...base, kind: "install", install: "inst_1" })).toBeUndefined()
    expect(inviteSender({ ...base, kind: "session", agent: "agent_x" })).toBeUndefined()
    expect(inviteSender({ ...base, kind: "agent" })).toBeUndefined()
    expect(inviteSender({ ...base, kind: "system" })).toBeUndefined()
  })
})
