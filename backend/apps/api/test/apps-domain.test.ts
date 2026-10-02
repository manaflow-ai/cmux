import { idFactory, type Origin, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { emptyApps, reduceApps, releaseSelector, type AppsSlice, type InstallsOwner } from "../src/domains/app-installs.ts"
import { latestOf, makeAppDomain, parseGithubRepo, resolveRelease, type AppState } from "../src/domains/app.ts"
import { compareVersions, maxSatisfying, satisfies } from "../src/domains/semver.ts"
import { prefixTsQuery } from "../src/app-store.ts"

const alice: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }
const bob: Principal = { identity: "session:user_bbbbbbbbbbbbbbbbbbbb", kind: "session", user: "user_bbbbbbbbbbbbbbbbbbbb", team: "team_bbbbbbbbbbbbbbbbbbbb" }
const staff: Principal = { identity: "session:user_ssssssssssssssssssss", kind: "session", user: "user_ssssssssssssssssssss", team: "team_ssssssssssssssssssss" }
const aliceInstall: Principal = { identity: "inst_aaaaaaaaaaaaaaaaaaaa", kind: "install", user: alice.user!, team: alice.team!, install: "inst_aaaaaaaaaaaaaaaaaaaa", grant: "grant_aaaaaaaaaaaaaaaaaaaa" }
const agent: Principal = { ...aliceInstall, identity: "inst_agentaaaaaaaaaaaaaa", kind: "agent", agent: "agent_aaaaaaaaaaaaaaaaaaaa" }

let txn = 0
const ctx = (principal: Principal, now: number, origin: Origin = "cli"): ReduceContext => {
  const tx = `tx${txn++}`
  return { principal, now, tx, origin, newId: idFactory(tx) }
}

const T0 = Date.UTC(2026, 9, 2, 12, 0, 0)
const APP = "acme/prs"

const manifest = (version: string, scopes: Record<string, string> = { "workspace:read": "match branches" }, extra: Record<string, unknown> = {}) => ({
  manifestVersion: 1,
  id: APP,
  name: "PRs",
  version,
  description: "Pull requests in the sidebar.",
  publisher: { name: "Acme" },
  engines: { cmux: "^1.0" },
  scopes,
  optionalScopes: { "notification:post": "notify on review" },
  categories: ["sidebar", "git"],
  contributes: { sidebarSections: [] },
  ...extra
})

const submitParams = (version: string, extra: Record<string, unknown> = {}) => ({
  repo: "https://github.com/acme/prs",
  tag: `v${version}`,
  manifest: manifest(version),
  bundle_url: `https://github.com/acme/prs/releases/download/v${version}/app.tar.zst`,
  bundle_sha256: "a".repeat(64),
  ...extra,
  resolved: { entity: APP }
})

const devDomain = makeAppDomain({ environment: "test", staff: new Set([staff.user!]) })
const prodDomain = makeAppDomain({ environment: "production", staff: new Set([staff.user!]) })

const appApply = (d: typeof devDomain, s: AppState, p: Principal, op: string, params: unknown, now = T0) => {
  const r = d.reduce(s, op, params, ctx({ ...p, grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }, now))
  if (!r.ok) throw Object.assign(new Error(r.message), { code: r.code })
  return r
}

const published = (...versions: Array<string>) => {
  let s = devDomain.initial()
  for (const v of versions) s = appApply(devDomain, s, alice, "app.version.submit", submitParams(v)).state
  return s
}

describe("semver", () => {
  it("orders prereleases before releases and compares numerically", () => {
    expect(["1.0.0", "1.0.0-rc.1", "1.0.0-alpha", "0.9.10", "0.9.9", "1.0.0-rc.10"].sort(compareVersions)).toEqual(["0.9.9", "0.9.10", "1.0.0-alpha", "1.0.0-rc.1", "1.0.0-rc.10", "1.0.0"])
  })
  it("matches caret, tilde, exact, x and >= ranges; prereleases only by name", () => {
    expect(satisfies("1.4.2", "^1.2")).toBe(true)
    expect(satisfies("2.0.0", "^1.2")).toBe(false)
    expect(satisfies("0.2.9", "^0.2.1")).toBe(true)
    expect(satisfies("0.3.0", "^0.2.1")).toBe(false)
    expect(satisfies("1.2.9", "~1.2.3")).toBe(true)
    expect(satisfies("1.3.0", "~1.2.3")).toBe(false)
    expect(satisfies("1.9.0", "1.x")).toBe(true)
    expect(satisfies("3.0.0", ">=1.0.0")).toBe(true)
    expect(satisfies("1.0.0-rc.1", "*")).toBe(false)
    expect(satisfies("1.0.0-rc.2", "^1.0.0-rc.1")).toBe(true)
    expect(maxSatisfying(["1.0.0", "1.2.0", "2.0.0"], "^1")).toBe("1.2.0")
    expect(satisfies("1.0.0", "garbage")).toBe(false)
  })
})

describe("AppDO reducer", () => {
  it("claims the id in a development-like environment and records the version", () => {
    const r = appApply(devDomain, devDomain.initial(), alice, "app.version.submit", submitParams("1.0.0"))
    const l = r.state.listing!
    expect(l).toMatchObject({ id: APP, publisher_team: alice.team, tier: "unverified", latest_version: "1.0.0", repository: "https://github.com/acme/prs" })
    expect(r.state.versions["1.0.0"]).toMatchObject({ scopes: { "workspace:read": "match branches" }, optional_scopes: { "notification:post": "notify on review" }, added_scopes: ["notification:post", "workspace:read"] })
    expect(r.outbox?.map((o) => o.kind)).toEqual(["app.upsert", "app_version.upsert"])
    // The full manifest goes to the projection only, never into DO state.
    expect((r.outbox![1]!.payload as { manifest: unknown }).manifest).toEqual(manifest("1.0.0"))
  })

  it("rejects version reuse, also after a yank", () => {
    const s = published("1.0.0")
    expect(() => appApply(devDomain, s, alice, "app.version.submit", submitParams("1.0.0"))).toThrow(/already published/)
    const y = appApply(devDomain, s, alice, "app.version.yank", { app: APP, version: "1.0.0", reason: "broken", resolved: { entity: APP } }).state
    try {
      appApply(devDomain, y, alice, "app.version.submit", submitParams("1.0.0"))
      expect.unreachable()
    } catch (e) {
      expect((e as { code: string }).code).toBe("version.exists")
    }
  })

  it("checks tag, repository owner, scope names, engines and the bound entity", () => {
    const s0 = devDomain.initial()
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), tag: "1.0.0" })).toThrow(/tag 1.0.0 must be v1.0.0/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), repo: "https://github.com/someone-else/prs" })).toThrow(/not the repository owner/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), manifest: manifest("1.0.0", { "bad scope": "x" }) })).toThrow(/family:detail/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), manifest: manifest("1.0.0", undefined, { engines: { cmux: "soon" } }) })).toThrow(/not a version range/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), manifest: { ...manifest("1.0.0"), version: "1.0" }, tag: "v1.0" })).toThrow(/essentials/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), resolved: { entity: "acme/other" } })).toThrow(/is not this app/)
    expect(() => appApply(devDomain, s0, alice, "app.version.submit", { ...submitParams("1.0.0"), resolved: undefined })).toThrow(/did not bind/)
  })

  it("only the publishing team (or staff) submits later versions", () => {
    const s = published("1.0.0")
    expect(() => appApply(devDomain, s, bob, "app.version.submit", submitParams("1.1.0"))).toThrow(/publishing team/)
    expect(appApply(devDomain, s, staff, "app.version.submit", submitParams("1.1.0")).state.listing!.latest_version).toBe("1.1.0")
  })

  it("outside development, ids are claimed only by staff; reserved publishers only by staff everywhere", () => {
    expect(() => appApply(prodDomain, prodDomain.initial(), alice, "app.version.submit", submitParams("1.0.0"))).toThrow(/verified publisher/)
    expect(appApply(prodDomain, prodDomain.initial(), staff, "app.version.submit", submitParams("1.0.0")).state.listing!.tier).toBe("unverified")
    const fp = { ...submitParams("1.0.0"), repo: "https://github.com/manaflow-ai/prs", manifest: { ...manifest("1.0.0"), id: "manaflow-ai/prs" }, resolved: { entity: "manaflow-ai/prs" } }
    expect(() => appApply(devDomain, devDomain.initial(), alice, "app.version.submit", fp)).toThrow(/claim_forbidden|verified publisher/)
    expect(appApply(devDomain, devDomain.initial(), staff, "app.version.submit", fp).state.listing!.tier).toBe("first-party")
  })

  it("yank moves latest back, is idempotent, and is publisher or staff only", () => {
    const s = published("1.0.0", "1.1.0")
    expect(() => appApply(devDomain, s, bob, "app.version.yank", { app: APP, version: "1.1.0", reason: "x", resolved: { entity: APP } })).toThrow(/publisher or cmux staff/)
    const y = appApply(devDomain, s, alice, "app.version.yank", { app: APP, version: "1.1.0", reason: "crash", resolved: { entity: APP } })
    expect(y.state.listing!.latest_version).toBe("1.0.0")
    expect(y.state.versions["1.1.0"]).toMatchObject({ yanked: true, yank_reason: "crash" })
    expect(appApply(devDomain, y.state, alice, "app.version.yank", { app: APP, version: "1.1.0", reason: "again", resolved: { entity: APP } }).changed).toBe(false)
    // The resolver never picks a yanked version for a range; an exact request sees the yank.
    expect(resolveRelease(y.state, 9, { range: "*" })?.version).toBe("1.0.0")
    expect(resolveRelease(y.state, 9, { version: "1.1.0" })?.yanked).toBe(true)
    expect(latestOf({})).toBeNull()
  })

  it("set_tier is staff only and first-party only for reserved publishers", () => {
    const s = published("1.0.0")
    expect(() => appApply(devDomain, s, alice, "app.listing.set_tier", { app: APP, tier: "verified", resolved: { entity: APP } })).toThrow(/staff/)
    expect(() => appApply(devDomain, s, staff, "app.listing.set_tier", { app: APP, tier: "first-party", resolved: { entity: APP } })).toThrow(/reserved/)
    expect(appApply(devDomain, s, staff, "app.listing.set_tier", { app: APP, tier: "community", resolved: { entity: APP } }).state.listing!.tier).toBe("community")
  })

  it("parses only https GitHub repository URLs", () => {
    expect(parseGithubRepo("https://github.com/Acme/PRs.git")).toEqual({ owner: "acme", repo: "prs" })
    expect(parseGithubRepo("http://github.com/acme/prs")).toBeNull()
    expect(parseGithubRepo("https://github.com/acme/prs/tree/main")).toBeNull()
  })
})

// ---------------------------------------------------------------- installs

const release = (version = "1.0.0", over: Partial<Record<string, unknown>> = {}) => ({
  app: APP,
  version,
  tier: "community",
  publisher_team: "team_pppppppppppppppppppp",
  scopes: ["workspace:read"],
  optional_scopes: ["notification:post"],
  engines: { cmux: "^1.0" },
  bundle_url: "https://x/app.tar.zst",
  bundle_sha256: "a".repeat(64),
  yanked: false,
  app_revision: "4",
  ...over
})

const user: InstallsOwner = { scope: "user", scopeId: alice.user!, canManage: true }
const team: InstallsOwner = { scope: "team", scopeId: alice.team!, canManage: true }

const apply = (s: AppsSlice, p: Principal, op: string, params: Record<string, unknown>, opts: { owner?: InstallsOwner; origin?: Origin; now?: number } = {}) => {
  const r = reduceApps(s, op, params, ctx(p, opts.now ?? T0, opts.origin ?? "cli"), opts.owner ?? user)
  if (!r.ok) throw Object.assign(new Error(r.message), { code: r.code, details: r.details })
  return r
}
const code = (fn: () => unknown) => {
  try {
    fn()
  } catch (e) {
    return (e as { code: string }).code
  }
  return "ok"
}

describe("installs and grants", () => {
  it("installs with granted scopes inside the version's scopes and writes one projection row", () => {
    const r = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() })
    expect(r.value).toMatchObject({ status: "installed", install: { app: APP, version: "1.0.0", scopes_granted: ["workspace:read"], app_revision: "4" } })
    expect(r.outbox).toEqual([{ kind: "app_install.upsert", entity: `${APP}:user:${alice.user}`, payload: { app: APP, scope_kind: "user", scope_id: alice.user, version: "1.0.0", installed_at: T0, removed_at: null } }])
    // Same install again changes nothing (no event, no row).
    expect(apply(r.state, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).changed).toBe(false)
  })

  it("refuses scopes outside the version and installs missing a required scope", () => {
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: [], resolved: release() }))).toBe("scope.invalid")
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read", "terminal:write"], resolved: release() }))).toBe("scope.invalid")
    expect(apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read", "notification:post"], resolved: release() }).state.installs[APP]!.scopes_granted).toEqual(["notification:post", "workspace:read"])
  })

  it("never trusts a missing or foreign lookup; refuses yanked and unverified without consent", () => {
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: null }))).toBe("selector.not_found")
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: { app: APP } }))).toBe("operation.failed")
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release("1.0.0", { app: "acme/other" }) }))).toBe("operation.failed")
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release("1.0.0", { yanked: true }) }))).toBe("app.yanked")
    expect(code(() => apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release("1.0.0", { tier: "unverified" }) }))).toBe("app.unverified")
    expect(apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], accept_unverified: true, resolved: release("1.0.0", { tier: "unverified" }) }).value).toMatchObject({ status: "installed" })
  })

  it("update carries scopes, needs consent for new required scopes, and the range comes from the install", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, version_range: "^1", scopes: ["workspace:read"], resolved: release() }).state
    expect(releaseSelector(s, "app.update", { app: APP })).toEqual({ app: APP, range: "^1" })
    const grown = release("1.1.0", { scopes: ["workspace:read", "terminal:read"] })
    const e = code(() => apply(s, alice, "app.update", { app: APP, resolved: grown }))
    expect(e).toBe("scope.consent_required")
    const u = apply(s, alice, "app.update", { app: APP, accept_scopes: ["terminal:read"], resolved: grown })
    expect(u.state.installs[APP]).toMatchObject({ version: "1.1.0", scopes_granted: ["terminal:read", "workspace:read"], installed_at: T0 })
    // A scope the new version no longer requests is dropped.
    const shrunk = apply(u.state, alice, "app.update", { app: APP, resolved: release("1.2.0", { scopes: ["terminal:read"], optional_scopes: [] }) })
    expect(shrunk.state.installs[APP]!.scopes_granted).toEqual(["terminal:read"])
    expect(code(() => apply(emptyApps, alice, "app.update", { app: APP, resolved: release() }))).toBe("selector.not_found")
  })

  it("grant.set stays within the version's scopes and only from the user's own client", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    expect(code(() => apply(s, alice, "app.grant.set", { app: APP, scopes: ["workspace:read", "notification:post"] }))).toBe("auth.forbidden")
    expect(code(() => apply(s, aliceInstall, "app.grant.set", { app: APP, scopes: ["workspace:read"] }, { origin: "user" }))).toBe("auth.forbidden")
    expect(code(() => apply(s, alice, "app.grant.set", { app: APP, scopes: ["workspace:write"] }, { origin: "user" }))).toBe("scope.invalid")
    const g = apply(s, alice, "app.grant.set", { app: APP, scopes: ["workspace:read", "notification:post"] }, { origin: "user" })
    expect((g.value as { scopes_granted: Array<string> }).scopes_granted).toEqual(["notification:post", "workspace:read"])
    expect(g.outbox ?? []).toEqual([]) // grants are never projected
  })

  it("remove deletes the install and marks the projection row removed; removing again is a no-op", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    const r = apply(s, alice, "app.remove", { app: APP }, { now: T0 + 5 })
    expect(r.state.installs).toEqual({})
    expect((r.outbox![0]!.payload as { removed_at: number }).removed_at).toBe(T0 + 5)
    expect(apply(r.state, alice, "app.remove", { app: APP }).changed).toBe(false)
  })
})

describe("agent approvals (D48)", () => {
  it("an agent's install (agent principal or origin mcp) waits for approval and installs nothing", () => {
    for (const [p, origin] of [[agent, "cli"], [aliceInstall, "mcp"]] as const) {
      const r = apply(emptyApps, p, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { origin })
      const v = r.value as { status: string; approval: { id: string; status: string; added: Array<string>; expires_at: number; requested_by: { origin: string } } }
      expect(v.status).toBe("approval_required")
      expect(v.approval).toMatchObject({ status: "pending", added: ["workspace:read"], expires_at: T0 + 10 * 60_000, requested_by: { origin } })
      expect(r.state.installs).toEqual({})
      expect(r.outbox ?? []).toEqual([])
    }
  })

  it("the user approves with the release re-resolved at decision time; agents and MCP cannot decide", () => {
    const req = apply(emptyApps, agent, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() })
    const id = (req.value as { approval: { id: string } }).approval.id
    expect(releaseSelector(req.state, "app.approval.decide", { approval: id })).toEqual({ app: APP, version: "1.0.0" })
    expect(code(() => apply(req.state, aliceInstall, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }))).toBe("auth.forbidden")
    expect(code(() => apply(req.state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "mcp" }))).toBe("auth.forbidden")
    expect(code(() => apply(req.state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release("1.0.0", { yanked: true }) }))).toBe("app.yanked")
    const ok = apply(req.state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "user", now: T0 + 1000 })
    expect(ok.value).toMatchObject({ approval: { status: "approved", decided_by: alice.identity }, install: { app: APP, installed_by: agent.identity } })
    expect(ok.outbox?.map((o) => o.kind)).toEqual(["app_install.upsert"])
    expect(code(() => apply(ok.state, alice, "app.approval.decide", { approval: id, decision: "deny" }))).toBe("approval.decided")
  })

  it("deny installs nothing; an expired request cannot be approved", () => {
    const req = apply(emptyApps, agent, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() })
    const id = (req.value as { approval: { id: string } }).approval.id
    const denied = apply(req.state, alice, "app.approval.decide", { approval: id, decision: "deny" })
    expect(denied.state.installs).toEqual({})
    expect(denied.state.approvals[id]!.status).toBe("denied")
    expect(code(() => apply(req.state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { now: T0 + 10 * 60_000 }))).toBe("approval.decided")
  })

  it("an agent's update that grows scopes needs approval; one that does not applies", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    const same = apply(s, agent, "app.update", { app: APP, resolved: release("1.0.1") })
    expect(same.value).toMatchObject({ status: "installed", install: { version: "1.0.1" } })
    const grow = apply(s, agent, "app.update", { app: APP, accept_scopes: ["notification:post"], resolved: release("1.0.1") })
    expect(grow.value).toMatchObject({ status: "approval_required", approval: { kind: "update", added: ["notification:post"] } })
    expect(grow.state.installs[APP]!.version).toBe("1.0.0")
  })
})

describe("team installs and the team app policy", () => {
  const withPolicy = (policy: Record<string, unknown>) => apply(emptyApps, alice, "app.policy.set", policy, { owner: team }).state

  it("needs a team admin", () => {
    expect(code(() => apply(emptyApps, bob, "app.install", { app: APP, scopes: ["workspace:read"], scope: "team", resolved: release() }, { owner: { ...team, canManage: false } }))).toBe("auth.forbidden")
  })

  it("enforces allowed tiers, the allowlist and the blocklist on installs and approvals", () => {
    const tiers = withPolicy({ allowed_tiers: ["first-party", "verified"] })
    expect(code(() => apply(tiers, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const allow = withPolicy({ allowlist: ["acme/other"] })
    expect(code(() => apply(allow, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const block = withPolicy({ blocklist: [APP] })
    expect(code(() => apply(block, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const open = withPolicy({})
    const ok = apply(open, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team })
    expect(ok.outbox?.[0]?.payload).toMatchObject({ scope_kind: "team", scope_id: alice.team })
    // The policy tightens after an agent asked: the approval is refused at decision time.
    const req = apply(open, agent, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team })
    const id = (req.value as { approval: { id: string } }).approval.id
    const tightened = apply(req.state, alice, "app.policy.set", { blocklist: [APP] }, { owner: team }).state
    expect(code(() => apply(tightened, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { owner: team }))).toBe("policy.denied")
  })

  it("policy.set is a team op and an unchanged policy is a no-op", () => {
    expect(code(() => apply(emptyApps, alice, "app.policy.set", {}, { owner: user }))).toBe("validation.invalid")
    const s = withPolicy({ allowed_tiers: ["verified", "first-party"] })
    expect(s.policy).toEqual({ allowed_tiers: ["first-party", "verified"], allowlist: null, blocklist: [] })
    expect(apply(s, alice, "app.policy.set", { allowed_tiers: ["first-party", "verified"] }, { owner: team }).changed).toBe(false)
  })
})

describe("invariant: a grant never leaves its version's scopes (random op sequences)", () => {
  it("holds for 2000 random sequences of install, update, grant, approval and remove", () => {
    let seed = 7
    // High bits of the LCG: its low bits cycle with short periods and correlate successive picks.
    const rnd = (n: number) => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) >>> 16) % n
    const pool = ["workspace:read", "terminal:read", "notification:post", "net:api.github.com"]
    const pick = () => pool.filter(() => rnd(2) === 0)
    const applied: Record<string, number> = {}
    for (let run = 0; run < 2000; run++) {
      let s: AppsSlice = emptyApps
      let now = T0
      for (let step = 0; step < 12; step++) {
        now += rnd(4) * 60_000
        const req = pick()
        const rel = release(`1.${step}.0`, { scopes: req, optional_scopes: pool.filter((x) => !req.includes(x) && rnd(2) === 0), yanked: rnd(10) === 0 })
        const actor = rnd(3) === 0 ? agent : alice
        const ops: Array<[string, Record<string, unknown>]> = [
          ["app.install", { app: APP, scopes: pick(), resolved: rel }],
          ["app.update", { app: APP, accept_scopes: pick(), resolved: rel }],
          ["app.grant.set", { app: APP, scopes: pick() }],
          ["app.remove", { app: APP }],
          ["app.approval.decide", { approval: Object.keys(s.approvals)[rnd(Math.max(1, Object.keys(s.approvals).length))] ?? "appr_x", decision: rnd(2) ? "approve" : "deny", resolved: rel }]
        ]
        const [op, params] = ops[rnd(ops.length)]!
        const r = reduceApps(s, op, params, ctx(actor, now, actor === agent ? "cli" : "user"), user)
        if (r.ok) {
          // An agent alone never adds an install or grows a grant.
          if (actor === agent && op !== "app.remove") {
            for (const [app, i] of Object.entries(r.state.installs)) {
              const before = s.installs[app]
              if (!before) expect(op).toBe("never: agent created an install")
              else for (const sc of i.scopes_granted) expect(before.scopes_granted.includes(sc) || op === "app.update").toBe(true)
              if (before && op === "app.update") expect(i.scopes_granted.every((sc) => before.scopes_granted.includes(sc))).toBe(true)
            }
          }
          s = r.state
          if (r.changed !== false) applied[op] = (applied[op] ?? 0) + 1
        }
        for (const i of Object.values(s.installs)) {
          for (const sc of i.version_scopes) expect(i.scopes_granted).toContain(sc)
          for (const sc of i.scopes_granted) expect([...i.version_scopes, ...i.version_optional_scopes]).toContain(sc)
        }
      }
    }
    // The sequences reach every op, so the invariant is not vacuous.
    for (const op of ["app.install", "app.update", "app.grant.set", "app.remove", "app.approval.decide"]) expect(applied[op] ?? 0, op).toBeGreaterThan(5)
  })
})

describe("search query", () => {
  it("builds a word-prefix tsquery from letters and digits only", () => {
    expect(prefixTsQuery("GitHub pull-req")).toBe("github:* & pull:* & req:*")
    expect(prefixTsQuery("a' | !b & (c:*) <-> d")).toBe("a:* & b:* & c:* & d:*")
    expect(prefixTsQuery("  ")).toBeNull()
    expect(prefixTsQuery(undefined)).toBeNull()
  })
})
