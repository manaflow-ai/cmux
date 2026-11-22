import type { Principal, ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { userDomain, type UserState } from "../src/domains/user.ts"
import { pairingServerPrincipal } from "../src/pair-routes.ts"

/**
 * Review P1 (CLOUD-LINK-FOLLOWUPS 4): the daemon install that pairing registers through the server
 * path keeps the approver's SSO team, so a paired daemon in an SSO-required team is not refused.
 */

const OWNER = "user_00000000000000000001"
const TEAM = "team_00000000000000000001"
const state = { user: { id: OWNER, stack_user_id: "s", email: null, display_name: "o", personal_team: TEAM }, installs: {}, grants: {} } as unknown as UserState
const params = { public_jwk: { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) }, kind: "daemon", name: "Studio", device_name: "Studio", platform: "linux", op_classes: ["read", "mutate-own"], bound_team: TEAM }

describe("paired daemon keeps the approver's SSO team", () => {
  it("the pairing server principal carries the approver's sso_team", () => {
    const approver: Principal = { identity: `user:${OWNER}`, user: OWNER, team: TEAM, kind: "session", sso_team: TEAM }
    expect(pairingServerPrincipal(approver, TEAM)).toMatchObject({ kind: "system", user: OWNER, team: TEAM, sso_team: TEAM })
    expect(pairingServerPrincipal({ ...approver, sso_team: undefined }, TEAM)).not.toHaveProperty("sso_team")
  })

  it("install.register_server records sso_team from the server principal", () => {
    const ctx: ReduceContext = { principal: { identity: `system:pairing:${TEAM}`, kind: "system", user: OWNER, team: TEAM, sso_team: TEAM }, now: 5, tx: "t", newId: (p) => `${p}_00000000000000000001` }
    const r = userDomain.reduce(state, "install.register_server", params, ctx)
    if (!r.ok) throw new Error(r.message)
    expect(r.value).toMatchObject({ kind: "daemon", sso_team: TEAM, bound_team: TEAM })
  })
})
