import { idFactory, STATE_MAX_BYTES, stateFull, utf8Length, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { evictStaleInstalls, installActive, MAX_ACTIVE_INSTALLS, userDomain, userPathAllowed, type UserState } from "../src/domains/user.ts"

/**
 * cmux-platform#1843: a copy of the app deleted without signing out leaves its install active for
 * good. The production cloud-chat probe ran a fresh app copy every run, so its account filled with
 * active installs, which the revoked-install prune never drops, until every commit was refused
 * (owner.state_full) and sign-in failed. A register now signs out the stalest client installs past
 * MAX_ACTIVE_INSTALLS in the same commit, so such a head heals on its next register.
 */

const USER = "user_aaaaaaaaaaaaaaaaaaaa"
const TEAM = "team_aaaaaaaaaaaaaaaaaaaa"
const session: Principal = { identity: `session:${USER}`, kind: "session", user: USER }
const id = (prefix: string, k: number) => `${prefix}_${String(k).padStart(20, "0")}`
const jwk = (k: number) => ({ kty: "EC", crv: "P-256", x: String(k).padStart(43, "x"), y: "y".repeat(43) })

const seed = (active: number, kind = "mac", extra: Partial<UserState> = {}): UserState => {
  const installs: Record<string, unknown> = {}
  const grants: Record<string, unknown> = {}
  for (let k = 0; k < active; k++) {
    installs[id("inst", k)] = { id: id("inst", k), device: id("dev", k), kind, name: "cmux probe", device_name: "probe runner", platform: "macos", public_jwk: jwk(k), thumbprint: `tp${k}`, grant: id("grant", k), created_at: k, revoked_at: null, ...(kind === "team-vm" ? { bound_team: TEAM } : {}) }
    grants[id("grant", k)] = { id: id("grant", k), grantee: id("inst", k), op_classes: ["read", "mutate-own", "mutate-shared", "cloud-link"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
  }
  return {
    user: { id: USER, stack_user_id: "s", email: "probe@example.com", email_verified: true, display_name: "probe", personal_team: TEAM },
    installs,
    grants,
    ...extra
  } as unknown as UserState
}

const activeCount = (s: UserState) => Object.values(s.installs).filter((i) => i.revoked_at === null).length
const register = (s: UserState, k: number) =>
  userDomain.reduce(s, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: String(k).padStart(43, "n"), y: "z".repeat(43) }, kind: "mac", name: "cmux", device_name: "probe runner", platform: "macos" }, { principal: session, now: 1_000_000, tx: `tx${k}`, newId: idFactory(`tx${k}`) })
const installPrincipal = (k: number): Principal => ({ identity: id("inst", k), kind: "install", user: USER, install: id("inst", k), grant: id("grant", k) })

describe("UserDO signs out the stalest client installs past MAX_ACTIVE_INSTALLS", () => {
  it("a head full of active installs heals on its next install.register", () => {
    const full = seed(3_000)
    expect(utf8Length(JSON.stringify(full))).toBeGreaterThan(STATE_MAX_BYTES)
    const r = register(full, 99_999)
    expect(r.ok, JSON.stringify(r).slice(0, 300)).toBe(true)
    if (!r.ok) return
    // The engine refuses exactly when stateFull answers (engine.ts, state-guard.ts).
    expect(stateFull(JSON.stringify(r.state), "user:test", "install.register")).toBeUndefined()
    expect(activeCount(r.state)).toBe(MAX_ACTIVE_INSTALLS)
    // The oldest went with their grants and incarnations; the newest and the new one stay.
    expect(r.state.installs[id("inst", 0)]).toBeUndefined()
    expect(r.state.grants[id("grant", 0)]).toBeUndefined()
    expect(Object.keys(r.state.install_authority?.incarnations ?? {})).not.toContain(id("inst", 0))
    expect(r.state.installs[id("inst", 2_999)]?.revoked_at).toBeNull()
    expect(r.state.installs[(r.value as { id: string }).id]?.revoked_at).toBeNull()
    // Each evicted install still gets its KRL notice and an install.upsert that says it is revoked.
    expect(r.state.ssh_revoke_pending?.[id("inst", 0)]).toEqual({ user: USER, teams: [TEAM], at: 1_000_000 })
    const upserts = (r.outbox ?? []).filter((o) => o.kind === "install.upsert")
    expect(upserts.length).toBe(3_000 - MAX_ACTIVE_INSTALLS + 2)
    expect(upserts.find((o) => o.entity === id("inst", 0))?.payload).toMatchObject({ revoked_at: 1_000_000 })
  })

  it("an evicted install's principal is refused", () => {
    const r = register(seed(MAX_ACTIVE_INSTALLS + 3), 99_998)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    for (const k of [0, 1, 2, 3]) {
      expect(installActive(r.state, installPrincipal(k))).toBe(false)
      expect(userPathAllowed(r.state, installPrincipal(k))).toBe(false)
    }
    expect(installActive(r.state, installPrincipal(4))).toBe(true)
    expect(userDomain.authorize?.(r.state, "install.rename", { install: id("inst", 0), name: "x" }, installPrincipal(0), undefined as never)).toMatchObject({ code: "auth.forbidden" })
  })

  it("nothing is evicted under the cap", () => {
    const under = seed(MAX_ACTIVE_INSTALLS - 1)
    expect(evictStaleInstalls(under, 1).state).toBe(under)
    const r = register(under, 99_997)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(activeCount(r.state)).toBe(MAX_ACTIVE_INSTALLS)
    expect(r.state.ssh_revoke_pending).toBeUndefined()
  })

  it("installs a push target or live presence key names go last", () => {
    const s = seed(MAX_ACTIVE_INSTALLS, "mac", {
      push_targets: { pt_1: { install: id("inst", 0) } },
      confirm: { presence_keys: { [id("inst", 1)]: { revoked_at: null } } }
    } as unknown as Partial<UserState>)
    const { evicted } = evictStaleInstalls(s, 5, 2)
    expect(evicted).toEqual([id("inst", 2), id("inst", 3)])
  })

  it("server installs (team-vm, vm, daemon) are never evicted or counted", () => {
    const machines = seed(MAX_ACTIVE_INSTALLS + 50, "team-vm")
    const r = register(machines, 99_996)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(activeCount(r.state)).toBe(MAX_ACTIVE_INSTALLS + 51)
  })

  it("an evicted install's presence key goes with it, so the head stays bounded over many evictions (11-25 recurrence)", () => {
    // Every install has a presence key: the probe's app registered one each run.
    const presence_keys: Record<string, unknown> = {}
    for (let k = 0; k < 3_000; k++) presence_keys[id("inst", k)] = { public_jwk: jwk(k), created_at: k, revoked_at: k % 2 === 0 ? null : k, attested: false }
    const s = seed(3_000, "mac", { confirm: { level: null, locks: {}, rev: 0, challenges: [], presence_keys, audit: [] } } as unknown as Partial<UserState>)
    const r = register(s, 99_995)
    expect(r.ok, JSON.stringify(r).slice(0, 300)).toBe(true)
    if (!r.ok) return
    const keys = Object.keys(r.state.confirm?.presence_keys ?? {})
    // No revoked presence key outlives its install.
    for (const install of keys) {
      const k = r.state.confirm!.presence_keys[install]!
      if (k.revoked_at !== null) expect(r.state.installs[install], install).toBeDefined()
    }
    expect(keys.length).toBeLessThanOrEqual(MAX_ACTIVE_INSTALLS + 1)
    expect(stateFull(JSON.stringify(r.state), "user:test", "install.register")).toBeUndefined()
    // Run after run (a fresh app copy each time) the head never grows past the bound again.
    let cur = r.state
    let bytes = 0
    for (let run = 0; run < 400; run++) {
      const n = register(cur, 200_000 + run)
      expect(n.ok).toBe(true)
      if (!n.ok) return
      cur = n.state
      bytes = Math.max(bytes, utf8Length(JSON.stringify(cur)))
    }
    expect(bytes).toBeLessThan(STATE_MAX_BYTES)
    expect(Object.keys(cur.confirm?.presence_keys ?? {}).every((i) => cur.installs[i])).toBe(true)
  })
})
