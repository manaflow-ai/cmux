import { idFactory, type Origin, type Principal, type ReduceContext } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { appsView, emptyApps, reduceApps, releaseSelector, requestApproval, type AppsSlice, type InstallsOwner } from "../src/domains/app-installs.ts"
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

  it("refuses build metadata (no precedence) and keeps the publisher's user id out of public views", () => {
    expect(() => appApply(devDomain, devDomain.initial(), alice, "app.version.submit", { ...submitParams("1.0.0+b1"), tag: "v1.0.0+b1" })).toThrow(/build metadata/)
    const r = appApply(devDomain, devDomain.initial(), alice, "app.version.submit", submitParams("1.0.0"))
    expect(r.state.versions["1.0.0"]!.published_by).toBe(alice.user)
    expect((r.value as { versions: Array<Record<string, unknown>> }).versions[0]).not.toHaveProperty("published_by")
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
    expect(appApply(devDomain, s, staff, "app.listing.set_tier", { app: APP, tier: "verified", resolved: { entity: APP } }).state.listing!.tier).toBe("verified")
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
  tier: "verified",
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
  const r = reduceApps(s, op, params, ctx(p, opts.now ?? T0, opts.origin ?? "user"), opts.owner ?? user)
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
    expect(r.outbox).toEqual([{ kind: "app_install.upsert", entity: `${APP}:user:${alice.user}`, payload: { app: APP, scope_kind: "user", scope_id: alice.user, version: "1.0.0", installed_at: T0, removed_at: null, hidden: false } }])
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
    expect(code(() => apply(s, alice, "app.grant.set", { app: APP, scopes: ["workspace:read", "notification:post"] }, { origin: "cli" }))).toBe("auth.forbidden")
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

/** Seeds an agent's pending request through the (currently unreachable) approval path. */
const ask = (s: AppsSlice, kind: "install" | "update", rel: ReturnType<typeof release>, scopes: Array<string>, opts: { owner?: InstallsOwner; now?: number; p?: Principal } = {}) => {
  const r = requestApproval(s, opts.owner ?? user, ctx(opts.p ?? agent, opts.now ?? T0, "mcp"), kind, rel as never, scopes, scopes.filter((x) => !(s.installs[rel.app]?.scopes_granted ?? []).includes(x)), "*")
  if (!r.ok) throw Object.assign(new Error(r.message), { code: r.code })
  return { state: r.state, id: (r.value as { approval: { id: string } }).approval.id, value: r.value as any, changed: r.changed }
}

describe("hide and unhide", () => {
  const isDefault = { resolved: { default: true } }
  it("hides and shows an installed app idempotently; the projection row carries hidden; updates keep it", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    const h = apply(s, aliceInstall, "app.hide", { app: APP, resolved: { default: false } }, { origin: "mcp" })
    expect(h.value).toEqual({ app: APP, hidden: true })
    expect(h.state.installs[APP]!.hidden).toBe(true)
    expect((h.outbox![0]!.payload as { hidden: boolean }).hidden).toBe(true)
    expect(apply(h.state, alice, "app.hide", { app: APP }).changed).toBe(false)
    expect(apply(h.state, alice, "app.update", { app: APP, resolved: release("1.0.1") }).state.installs[APP]!.hidden).toBe(true)
    const u = apply(h.state, alice, "app.unhide", { app: APP })
    expect(u.state.installs[APP]!.hidden).toBe(false)
    expect(apply(u.state, alice, "app.unhide", { app: APP }).changed).toBe(false)
  })

  it("a default first-party app is hidden, removed and installed again without an install record until then", () => {
    expect(code(() => apply(emptyApps, alice, "app.hide", { app: APP, resolved: { default: false } }))).toBe("selector.not_found")
    // A client cannot claim an app is a default one: only the owner's resolved answer counts, and only for user owners.
    expect(code(() => apply(emptyApps, alice, "app.hide", { app: APP, resolved: { default: true } }, { owner: team }))).toBe("validation.invalid")
    const h = apply(emptyApps, alice, "app.hide", { app: APP, ...isDefault })
    expect(h.state.defaults).toEqual({ [APP]: { removed_at: null, hidden: true } })
    expect(h.state.installs).toEqual({})
    expect(h.outbox ?? []).toEqual([])
    expect(apply(h.state, alice, "app.hide", { app: APP, ...isDefault }).changed).toBe(false)
    const r = apply(h.state, alice, "app.remove", { app: APP, ...isDefault }, { now: T0 + 9 })
    expect(r.value).toEqual({ app: APP, removed: true })
    expect(r.state.defaults![APP]).toEqual({ removed_at: T0 + 9, hidden: true })
    expect(apply(r.state, alice, "app.remove", { app: APP, ...isDefault }).changed).toBe(false)
    expect(code(() => apply(r.state, alice, "app.unhide", { app: APP, ...isDefault }))).toBe("selector.not_found")
    const again = apply(r.state, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release("1.0.0", { tier: "first-party" }) })
    expect(again.state.defaults![APP]!.removed_at).toBeNull()
    expect(again.state.installs[APP]!.hidden).toBe(true)
    // Removing the explicit install of a default app leaves it removed, not back as a default.
    expect(apply(again.state, alice, "app.remove", { app: APP, ...isDefault }).state.defaults![APP]!.removed_at).not.toBeNull()
  })

  it("app.list shows hidden (records from before hidden read as false) and keeps default prefs internal to user owners", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    const { hidden: _h, ...old } = s.installs[APP]!
    const legacy: AppsSlice = { ...s, installs: { [APP]: old as never } }
    expect(appsView(legacy, T0, "user").installs[0]!.hidden).toBe(false)
    expect(appsView(apply(s, alice, "app.hide", { app: APP }).state, T0, "user").installs[0]!.hidden).toBe(true)
    expect(appsView(s, T0, "team")).not.toHaveProperty("default_prefs")
  })
})

describe("phase 1: installs only from the user's own client (app.install.user_only)", () => {
  const install = { app: APP, scopes: ["workspace:read"], resolved: release() }
  it("app.install: origin cli and mcp are refused, origin user installs, an agent principal is refused even as user", () => {
    expect(code(() => apply(emptyApps, aliceInstall, "app.install", install, { origin: "cli" }))).toBe("app.install.user_only")
    expect(code(() => apply(emptyApps, aliceInstall, "app.install", install, { origin: "mcp" }))).toBe("app.install.user_only")
    expect(code(() => apply(emptyApps, alice, "app.install", install, { origin: "cli" }))).toBe("app.install.user_only")
    expect(code(() => apply(emptyApps, agent, "app.install", install, { origin: "user" }))).toBe("app.install.user_only")
    const r = apply(emptyApps, aliceInstall, "app.install", install, { origin: "user" })
    expect(r.value).toMatchObject({ status: "installed" })
    expect(Object.keys(r.state.approvals)).toEqual([])
  })

  it("app.update: growing scopes needs origin user; an update within the granted scopes does not", () => {
    const s = apply(emptyApps, alice, "app.install", install).state
    for (const origin of ["cli", "mcp"] as const) {
      expect(code(() => apply(s, aliceInstall, "app.update", { app: APP, accept_scopes: ["notification:post"], resolved: release("1.0.1") }, { origin }))).toBe("app.install.user_only")
      expect(apply(s, aliceInstall, "app.update", { app: APP, resolved: release("1.0.1") }, { origin }).value).toMatchObject({ status: "installed", install: { version: "1.0.1" } })
    }
    expect(code(() => apply(s, agent, "app.update", { app: APP, accept_scopes: ["notification:post"], resolved: release("1.0.1") }, { origin: "cli" }))).toBe("app.install.user_only")
    expect(apply(s, alice, "app.update", { app: APP, accept_scopes: ["notification:post"], resolved: release("1.0.1") }, { origin: "user" }).state.installs[APP]!.scopes_granted).toEqual(["notification:post", "workspace:read"])
  })

  it("app.approval.decide: origin cli and mcp are refused, origin user decides", () => {
    const { state, id } = ask(emptyApps, "install", release(), ["workspace:read"])
    expect(code(() => apply(state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "cli" }))).toBe("app.install.user_only")
    expect(code(() => apply(state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "mcp" }))).toBe("app.install.user_only")
    expect(code(() => apply(state, aliceInstall, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "user" }))).toBe("auth.forbidden")
    expect(apply(state, alice, "app.approval.decide", { approval: id, decision: "approve", resolved: release() }, { origin: "user" }).value).toMatchObject({ approval: { status: "approved" } })
  })
})

describe("agent approvals (D48; unreachable until the actor stamp, rules kept tested)", () => {
  it("a request records requester, scopes and expiry and installs nothing", () => {
    const { state, value } = ask(emptyApps, "install", release(), ["workspace:read"])
    expect(value).toMatchObject({ status: "approval_required", approval: { status: "pending", added: ["workspace:read"], expires_at: T0 + 10 * 60_000, requested_by: { origin: "mcp" }, base_version: null } })
    expect(state.installs).toEqual({})
  })

  it("the user approves with the release re-resolved at decision time", () => {
    const req = ask(emptyApps, "install", release(), ["workspace:read"])
    expect(releaseSelector(req.state, "app.approval.decide", { approval: req.id })).toEqual({ app: APP, version: "1.0.0" })
    expect(code(() => apply(req.state, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release("1.0.0", { yanked: true }) }))).toBe("app.yanked")
    const ok = apply(req.state, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release() }, { now: T0 + 1000 })
    expect(ok.value).toMatchObject({ approval: { status: "approved", decided_by: alice.identity }, install: { app: APP, installed_by: agent.identity } })
    expect(ok.outbox?.map((o) => o.kind)).toEqual(["app_install.upsert"])
    expect(code(() => apply(ok.state, alice, "app.approval.decide", { approval: req.id, decision: "deny" }))).toBe("approval.decided")
  })

  it("deny installs nothing; expiry is recorded", () => {
    const req = ask(emptyApps, "install", release(), ["workspace:read"])
    const denied = apply(req.state, alice, "app.approval.decide", { approval: req.id, decision: "deny" })
    expect(denied.state.installs).toEqual({})
    expect(denied.state.approvals[req.id]!.status).toBe("denied")
    const late = apply(req.state, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release() }, { now: T0 + 10 * 60_000 })
    expect(late.value).toMatchObject({ approval: { status: "expired" }, install: null })
    expect(code(() => apply(late.state, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release() }))).toBe("approval.decided")
  })

  it("an identical pending request is returned again, and at most 20 wait", () => {
    const first = ask(emptyApps, "install", release(), ["workspace:read"])
    const again = ask(first.state, "install", release(), ["workspace:read"], { now: T0 + 1000 })
    expect(again.changed).toBe(false)
    expect(again.id).toBe(first.id)
    let s = first.state
    for (let i = 1; i < 20; i++) s = ask(s, "install", release("1.0.0", { app: `acme/app${i}` }), ["workspace:read"]).state
    expect(code(() => ask(s, "install", release("1.0.0", { app: "acme/one-more" }), ["workspace:read"]))).toBe("approval.limit")
    expect(ask(s, "install", release("1.0.0", { app: "acme/one-more" }), ["workspace:read"], { now: T0 + 11 * 60_000 }).value).toMatchObject({ status: "approval_required" })
  })

  it("approving a request whose install changed since is refused as stale", () => {
    const s = apply(emptyApps, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }).state
    const req = ask(s, "update", release("1.0.1"), ["notification:post", "workspace:read"])
    expect(req.value.approval.base_version).toBe("1.0.0")
    const newer = apply(req.state, alice, "app.update", { app: APP, resolved: release("1.1.0") }).state
    expect(code(() => apply(newer, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release("1.0.1") }))).toBe("approval.stale")
    const removed = apply(req.state, alice, "app.remove", { app: APP }).state
    expect(code(() => apply(removed, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release("1.0.1") }))).toBe("approval.stale")
  })
})

describe("team installs and the team app policy", () => {
  const withPolicy = (policy: Record<string, unknown>) => apply(emptyApps, alice, "app.policy.set", policy, { owner: team }).state

  it("needs a team admin", () => {
    expect(code(() => apply(emptyApps, bob, "app.install", { app: APP, scopes: ["workspace:read"], scope: "team", resolved: release() }, { owner: { ...team, canManage: false } }))).toBe("auth.forbidden")
  })

  it("enforces allowed tiers, the allowlist and the blocklist on installs and approvals", () => {
    const tiers = withPolicy({ allowed_tiers: ["first-party"] })
    expect(code(() => apply(tiers, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const allow = withPolicy({ allowlist: ["acme/other"] })
    expect(code(() => apply(allow, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const block = withPolicy({ blocklist: [APP] })
    expect(code(() => apply(block, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team }))).toBe("policy.denied")
    const open = withPolicy({})
    const ok = apply(open, alice, "app.install", { app: APP, scopes: ["workspace:read"], resolved: release() }, { owner: team })
    expect(ok.outbox?.[0]?.payload).toMatchObject({ scope_kind: "team", scope_id: alice.team })
    // The policy tightens after an agent asked: the approval is refused at decision time.
    const req = ask(open, "install", release(), ["workspace:read"], { owner: team })
    const tightened = apply(req.state, alice, "app.policy.set", { blocklist: [APP] }, { owner: team }).state
    expect(code(() => apply(tightened, alice, "app.approval.decide", { approval: req.id, decision: "approve", resolved: release() }, { owner: team }))).toBe("policy.denied")
  })

  it("a team admits unverified apps only when its policy lists the tier", () => {
    const unverified = { app: APP, scopes: ["workspace:read"], accept_unverified: true, resolved: release("1.0.0", { tier: "unverified" }) }
    expect(code(() => apply(emptyApps, alice, "app.install", unverified, { owner: team }))).toBe("policy.denied")
    expect(apply(withPolicy({ allowed_tiers: ["verified", "unverified"] }), alice, "app.install", unverified, { owner: team }).value).toMatchObject({ status: "installed" })
  })

  it("team installs need a grant with mutate-shared (install tokens of an admin included)", async () => {
    const { teamDomain } = await import("../src/domains/team.ts")
    const state = { team: { id: alice.team!, kind: "personal" as const, display_name: "A" }, members: { [alice.user!]: { user: alice.user!, role: "owner" as const, display_name: "A" } }, hosts: {} }
    const ownOnly = { ...aliceInstall, grant_classes: ["read", "mutate-own"] }
    expect(teamDomain.authorize!(state, "app.install", { app: APP, scope: "team" }, ownOnly)?.message).toMatch(/mutate-shared/)
    expect(teamDomain.authorize!(state, "app.install", { app: APP, scope: "team" }, { ...ownOnly, grant_classes: ["read", "mutate-own", "mutate-shared"] })).toBeUndefined()
    const { userDomain } = await import("../src/domains/user.ts")
    const userState = { user: { id: alice.user!, stack_user_id: "s", email: null, display_name: "A", personal_team: alice.team! }, installs: { [aliceInstall.install!]: { id: aliceInstall.install!, grant: aliceInstall.grant!, revoked_at: null } as never }, grants: { [aliceInstall.grant!]: { id: aliceInstall.grant!, grantee: "x", op_classes: ["read", "mutate-own"] as Array<"read" | "mutate-own">, approval: "none" as const, expires_at: null, revoked_at: null, created_from: "install" as const } } }
    expect(userDomain.authorize!(userState, "app.install", { app: APP }, aliceInstall)).toBeUndefined()
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
        const r =
          actor === agent && op === "app.install"
            ? requestApproval(s, user, ctx(agent, now, "mcp"), "install", rel as never, params.scopes as Array<string>, params.scopes as Array<string>, "*")
            : reduceApps(s, op, params, ctx(actor, now, actor === agent ? "cli" : "user"), user)
        if (r.ok) {
          // An agent alone never adds an install or grows a grant.
          if (actor === agent && op !== "app.remove" && op !== "app.install") {
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
