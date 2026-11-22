import { idFactory, STATE_MAX_BYTES, stateFull, utf8Length, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { installActive, liveInstallGrant, MAX_REVOKED_INSTALLS, pruneRevokedInstalls, userDomain, userPathAllowed, type UserState } from "../src/domains/user.ts"

/**
 * Each sign-in and each bound machine used to leave a revoked install and its grant in the user's
 * head for good, until the head passed STATE_MAX_BYTES and every commit for that user was refused
 * (owner.state_full on install.register). The head now keeps at most MAX_REVOKED_INSTALLS revoked
 * installs, oldest revoked_at dropped first, and a register on a full head heals it in that commit.
 */

const USER = "user_aaaaaaaaaaaaaaaaaaaa"
const TEAM = "team_aaaaaaaaaaaaaaaaaaaa"
const session: Principal = { identity: `session:${USER}`, kind: "session", user: USER }
const id = (prefix: string, k: number) => `${prefix}_${String(k).padStart(20, "0")}`
const jwk = (k: number) => ({ kty: "EC", crv: "P-256", x: String(k).padStart(43, "x"), y: "y".repeat(43) })

const seed = (revoked: number, active = 1): UserState => {
  const installs: Record<string, unknown> = {}
  const grants: Record<string, unknown> = {}
  for (let k = 0; k < revoked + active; k++) {
    const live = k >= revoked
    installs[id("inst", k)] = { id: id("inst", k), device: id("dev", k), kind: "cli", name: "cmux probe", device_name: "probe runner", platform: "linux", public_jwk: jwk(k), thumbprint: `tp${k}`, grant: id("grant", k), created_at: k, revoked_at: live ? null : 10_000 + k }
    grants[id("grant", k)] = { id: id("grant", k), grantee: id("inst", k), op_classes: ["read", "mutate-own", "mutate-shared", "execute"], approval: "none", expires_at: null, revoked_at: live ? null : 10_000 + k, created_from: "install" }
  }
  return {
    user: { id: USER, stack_user_id: "s", email: "probe@example.com", email_verified: true, display_name: "probe", personal_team: TEAM },
    installs,
    grants
  } as unknown as UserState
}

const revokedCount = (s: UserState) => Object.values(s.installs).filter((i) => i.revoked_at !== null).length
const register = (s: UserState, k: number) =>
  userDomain.reduce(s, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: String(k).padStart(43, "n"), y: "z".repeat(43) }, kind: "cli", name: "cmux probe", device_name: "probe runner", platform: "linux" }, { principal: session, now: 1_000_000, tx: `tx${k}`, newId: idFactory(`tx${k}`) })
const installPrincipal = (k: number): Principal => ({ identity: id("inst", k), kind: "install", user: USER, install: id("inst", k), grant: id("grant", k) })

describe("UserDO keeps a bounded number of revoked installs", () => {
  it("a head already past the size limit heals on its next install.register", () => {
    const full = seed(3_000)
    expect(utf8Length(JSON.stringify(full))).toBeGreaterThan(STATE_MAX_BYTES)
    const r = register(full, 99_999)
    expect(r.ok, JSON.stringify(r).slice(0, 300)).toBe(true)
    if (!r.ok) return
    // The engine refuses exactly when stateFull answers (engine.ts, state-guard.ts).
    expect(stateFull(JSON.stringify(r.state), "user:test", "install.register")).toBeUndefined()
    expect(revokedCount(r.state)).toBe(MAX_REVOKED_INSTALLS)
    // The oldest revocations went with their grants; the newest stay; the live install and the new one stay.
    expect(r.state.installs[id("inst", 0)]).toBeUndefined()
    expect(r.state.grants[id("grant", 0)]).toBeUndefined()
    expect(r.state.installs[id("inst", 2_999)]?.revoked_at).not.toBeNull()
    expect(r.state.installs[id("inst", 3_000)]?.revoked_at).toBeNull()
    expect(r.state.installs[(r.value as { id: string }).id]).toBeDefined()
    // withInstallAuthority keeps no incarnation for a dropped install.
    expect(Object.keys(r.state.install_authority?.incarnations ?? {})).not.toContain(id("inst", 0))
    expect(Object.keys(r.state.installs).length).toBe(MAX_REVOKED_INSTALLS + 2)
  })

  it("a dropped install's principal is refused everywhere", () => {
    const r = register(seed(MAX_REVOKED_INSTALLS + 5), 99_998)
    if (!r.ok) throw new Error(r.message)
    const gone = installPrincipal(0)
    expect(r.state.installs[gone.install!]).toBeUndefined()
    expect(installActive(r.state, gone)).toBe(false)
    expect(userPathAllowed(r.state, gone)).toBe(false)
    expect(liveInstallGrant(r.state, gone, 1_000_001)).toBeUndefined()
    expect(userDomain.authorize?.(r.state, "install.rename", { install: gone.install, name: "x" }, gone, undefined as never)).toMatchObject({ code: "auth.forbidden" })
    // The live install still works.
    expect(installActive(r.state, installPrincipal(MAX_REVOKED_INSTALLS + 5))).toBe(true)
  })

  it("keeps installs named by a pending SSH revoke, a presence key or a push target", () => {
    const base = seed(MAX_REVOKED_INSTALLS + 10)
    const s = {
      ...base,
      ssh_revoke_pending: { [id("inst", 0)]: { user: USER, teams: [TEAM], at: 10_000 } },
      confirm: { presence_keys: { [id("inst", 1)]: { platform: "ios", revoked_at: 10_001 } } },
      push_targets: { tok: { token: "tok", topic: "dev.cmux.ios", environment: "production", install: id("inst", 2), device_name: "", registered_at: 1 } }
    } as unknown as UserState
    const after = pruneRevokedInstalls(s)
    for (const k of [0, 1, 2]) expect(after.installs[id("inst", k)], `inst ${k}`).toBeDefined()
    expect(after.grants[id("grant", 0)]).toBeDefined()
    // The next oldest unheld ones went instead.
    for (const k of [3, 12]) expect(after.installs[id("inst", k)], `inst ${k}`).toBeUndefined()
    expect(after.installs[id("inst", 13)]).toBeDefined()
    expect(revokedCount(after)).toBe(MAX_REVOKED_INSTALLS)
  })

  it("install.revoke prunes in the same commit; at or under the bound nothing changes", () => {
    const under = seed(MAX_REVOKED_INSTALLS)
    expect(pruneRevokedInstalls(under)).toBe(under)
    const r = userDomain.reduce(under, "install.revoke", { install: id("inst", MAX_REVOKED_INSTALLS) }, { principal: session, now: 2_000_000, tx: "txr", newId: idFactory("txr") })
    if (!r.ok) throw new Error(r.message)
    // The new revocation is pending its SSH notice, so it stays; the oldest went.
    expect(r.state.installs[id("inst", MAX_REVOKED_INSTALLS)]?.revoked_at).toBe(2_000_000)
    expect(r.state.installs[id("inst", 0)]).toBeUndefined()
    expect(revokedCount(r.state)).toBe(MAX_REVOKED_INSTALLS)
  })
})
