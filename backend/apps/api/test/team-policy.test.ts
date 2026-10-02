import { env, exports } from "cloudflare:workers"
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { policyKeys } from "@cmux/protocol"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { currentPolicy, integrationSlice, POLICY_HISTORY_LIMIT } from "../src/domains/team-policy.ts"
import { integrationSyncPending, sliceHash } from "../src/domains/team-integration-sync.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; CONNECTION_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"

const baseState = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "T" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "o" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "m" }
  },
  hosts: {}
})

let txn = 0
const ctx = (user = OWNER, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra },
  now: 1_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})

const run = (state: TeamState, op: string, params: unknown, c = ctx()) => teamDomain.reduce(state, op, params, c)

const set = (key: string, value: unknown, mode: "enforced" | "default" = "enforced") => ({ key, value: { value, mode } })

describe("team policy reducer (TeamDO single writer)", () => {
  it("old team objects without a policy field read as version 0 with no keys", () => {
    expect(currentPolicy(baseState())).toEqual({ version: 0, values: {}, updated_at: null, updated_by: null })
  })

  it("commits a typed change as version 1 with history, and a stale expected_version is a revision conflict", () => {
    const r = run(baseState(), "team.policy.update", { changes: [set("telemetry.level", "crash_only")], expected_version: 0, reason: "privacy" })
    expect(r.ok).toBe(true)
    if (!r.ok) return
    const s = r.state as TeamState
    expect(s.policy).toMatchObject({ version: 1, values: { "telemetry.level": { value: "crash_only", mode: "enforced" } }, updated_by: OWNER })
    expect(s.policy_history?.[0]).toMatchObject({ version: 1, changed: ["telemetry.level"], reason: "privacy", rollback_of: null })
    const stale = run(s, "team.policy.update", { changes: [set("telemetry.level", "off")], expected_version: 0 })
    expect(stale).toMatchObject({ ok: false, code: "revision.conflict" })
  })

  it("refuses members, agents, unknown keys, wrong value types, and out-of-range retention", () => {
    const s = baseState()
    expect(run(s, "team.policy.update", { changes: [set("telemetry.level", "off")], expected_version: 0 }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(run(s, "team.policy.update", { changes: [set("telemetry.level", "off")], expected_version: 0 }, ctx(OWNER, { kind: "agent", agent: "agent_x" }))).toMatchObject({
      ok: false,
      code: "auth.forbidden"
    })
    expect(run(s, "team.policy.update", { changes: [set("no.such.key", true)], expected_version: 0 })).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(run(s, "team.policy.update", { changes: [set("computerUse.allowed", "yes")], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(run(s, "team.policy.update", { changes: [set("retention.cuaFramesDays", 8)], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(run(s, "team.policy.update", { changes: [set("retention.auditDays", 30)], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(run(s, "team.policy.update", { changes: [set("telemetry.level", "off"), set("telemetry.level", "full")], expected_version: 0 })).toMatchObject({
      ok: false,
      code: "policy.invalid"
    })
  })

  it("refuses lockouts: enforced SSO without a connection", () => {
    const s = baseState()
    expect(run(s, "team.policy.update", { changes: [set("sso.enforce", true)], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    // A default (recommended) value cannot lock anyone out.
    expect(run(s, "team.policy.update", { changes: [set("sso.enforce", true, "default")], expected_version: 0 }).ok).toBe(true)
    expect(run(s, "team.policy.update", { changes: [set("github.repoScope", "allow_list")], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(run(s, "team.policy.update", { changes: [set("integrations.allowedProviders", ["notion"])], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
  })

  it("maps the integration keys onto ConnectionDO's TeamIntegrationPolicy fields", () => {
    expect(integrationSlice({})).toEqual({ allowed_providers: null, github: { scope: "linking_user_repos", require_org_admin: false, repo_allowlist: null } })
    expect(
      integrationSlice({
        "integrations.allowedProviders": { value: ["github"], mode: "enforced" },
        "github.repoScope": { value: "installation", mode: "default" },
        "github.requireOrgAdmin": { value: true, mode: "enforced" },
        "github.repoAllowList": { value: ["manaflow-ai/*"], mode: "enforced" }
      })
    ).toEqual({ allowed_providers: ["github"], github: { scope: "installation", require_org_admin: true, repo_allowlist: ["manaflow-ai/*"] } })
  })

  it("refuses a policy larger than 64 KB (review P2-4: TeamDO state is one SQLite row)", () => {
    const big = Object.fromEntries(Array.from({ length: 150 }, (_, i) => [`ui.k${i}`, { value: "x".repeat(600), mode: "enforced" }]))
    expect(run(baseState(), "team.policy.update", { changes: [set("device.settings", big)], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
  })

  it("a change that sets the current values is a no-op (no new version, no event)", () => {
    const r1 = run(baseState(), "team.policy.update", { changes: [set("mcp.server", "disabled")], expected_version: 0 })
    if (!r1.ok) throw new Error("setup")
    const r2 = run(r1.state as TeamState, "team.policy.update", { changes: [set("mcp.server", "disabled")], expected_version: 1 })
    expect(r2).toMatchObject({ ok: true, changed: false })
  })

  it("rollback applies a past version as a new version; clearing a key returns it to the product default", () => {
    let s = baseState()
    const apply = (op: string, params: unknown) => {
      const r = run(s, op, params)
      if (!r.ok) throw new Error(`${op}: ${r.message}`)
      s = r.state as TeamState
    }
    apply("team.policy.update", { changes: [set("updates.channel", "stable")], expected_version: 0 })
    apply("team.policy.update", { changes: [set("updates.channel", "nightly", "default"), set("cloud.sandboxes", false)], expected_version: 1 })
    apply("team.policy.update", { changes: [{ key: "cloud.sandboxes", value: null }], expected_version: 2 })
    expect(s.policy?.values["cloud.sandboxes"]).toBeUndefined()
    apply("team.policy.rollback", { version: 1, expected_version: 3 })
    expect(s.policy?.version).toBe(4)
    expect(s.policy?.values).toEqual(s.policy_history?.find((v) => v.version === 1)?.values)
    expect(s.policy_history?.[0]).toMatchObject({ version: 4, rollback_of: 1 })
    expect(run(s, "team.policy.rollback", { version: 99, expected_version: 4 })).toMatchObject({ ok: false, code: "selector.not_found" })
  })

  it("seeded random op sequences keep the invariants: versions never repeat or go back, history is bounded and newest first, values always decode", () => {
    // mulberry32: an LCG's low bits cycle too fast for small moduli.
    let seed = 0x2a
    const rand = (n: number) => {
      seed = (seed + 0x6d2b79f5) | 0
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
      return ((t ^ (t >>> 14)) >>> 0) % n
    }
    const samples: Record<string, ReadonlyArray<unknown>> = {
      "telemetry.level": ["full", "crash_only", "off", "bogus"],
      "computerUse.allowed": [true, false, 1],
      "retention.cuaEventsDays": [1, 15, 30, 31],
      "apps.install": ["any", "allow_list", "disabled"],
      "mcp.server": ["user_choice", "disabled"]
    }
    let s = baseState()
    let lastVersion = 0
    for (let i = 0; i < 400; i++) {
      const v = currentPolicy(s).version
      const r =
        rand(5) === 0
          ? run(s, "team.policy.rollback", { version: rand(v + 1), expected_version: rand(4) === 0 ? v + 1 : v })
          : run(s, "team.policy.update", {
              changes: [
                (() => {
                  const keys = Object.keys(samples)
                  const key = keys[rand(keys.length)]!
                  return rand(6) === 0 ? { key, value: null } : set(key, samples[key]![rand(samples[key]!.length)], rand(2) ? "enforced" : "default")
                })()
              ],
              expected_version: rand(8) === 0 ? v + 3 : v
            })
      if (!r.ok) continue
      s = r.state as TeamState
      const p = currentPolicy(s)
      expect(p.version).toBeGreaterThanOrEqual(lastVersion)
      if (r.changed !== false) expect(p.version).toBe(lastVersion + 1)
      lastVersion = p.version
      const hist = s.policy_history ?? []
      expect(hist.length).toBeLessThanOrEqual(POLICY_HISTORY_LIMIT)
      for (let j = 1; j < hist.length; j++) expect(hist[j - 1]!.version).toBeGreaterThan(hist[j]!.version)
      for (const k of Object.keys(p.values)) expect(policyKeys).toContain(k)
    }
    expect(lastVersion).toBeGreaterThan(50)
  })
})

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json()) as any }
}

describe("integration seed and slice sync (TeamDO)", () => {
  const sys = (): ReduceContext => ({ principal: { identity: "system:team", kind: "system" }, now: 5_000 + txn, tx: `tx${++txn}`, newId: (p) => `${p}_${String(txn).padStart(20, "0")}` })
  const admin = { allowed_providers: null, github: { scope: "linking_user_repos" as const, require_org_admin: true, repo_allowlist: ["acme/api"] } }

  it("copies only keys TeamPolicy has not set, then pushes only when the integration slice changes", () => {
    let s = run(baseState(), "team.policy.update", { changes: [set("github.repoAllowList", ["acme/web"]), set("telemetry.level", "off")], expected_version: 0 })
    if (!s.ok) throw new Error("setup")
    let state = s.state as TeamState
    expect(integrationSyncPending(state)).toBe(true)
    const seeded = teamDomain.reduce(state, "team.policy.integration_seed", { policy: admin }, sys())
    if (!seeded.ok) throw new Error(seeded.message)
    state = seeded.state as TeamState
    // The admin's TeamPolicy allow list wins; require_org_admin is copied.
    expect(state.policy?.values["github.repoAllowList"]).toEqual({ value: ["acme/web"], mode: "enforced" })
    expect(state.policy?.values["github.requireOrgAdmin"]).toEqual({ value: true, mode: "enforced" })
    expect(state.policy?.version).toBe(2)
    expect(integrationSyncPending(state)).toBe(true)
    const synced = teamDomain.reduce(state, "team.policy.integration_synced", { version: 2, slice_hash: sliceHash(integrationSlice(state.policy!.values)) }, sys())
    if (!synced.ok) throw new Error(synced.message)
    state = synced.state as TeamState
    expect(integrationSyncPending(state)).toBe(false)
    // An unrelated key does not need a push.
    const unrelated = run(state, "team.policy.update", { changes: [set("telemetry.level", "full")], expected_version: 2 })
    if (!unrelated.ok) throw new Error("unrelated")
    expect(integrationSyncPending(unrelated.state as TeamState)).toBe(false)
    // Seeding twice changes nothing; members cannot call the system ops.
    expect(teamDomain.reduce(state, "team.policy.integration_seed", { policy: admin }, sys())).toMatchObject({ ok: true, changed: false })
    expect(teamDomain.authorize!(state, "team.policy.integration_seed", { policy: admin }, { identity: `user:${OWNER}`, user: OWNER, team: TEAM, kind: "session" })).toMatchObject({ code: "auth.forbidden" })
  })
})

/**
 * TeamDO's alarm (scheduled for now by the commit) may already be running in
 * workerd; run any pending alarm and wait until the condition holds (test-only wait).
 */
const settle = async (check: () => Promise<boolean>, stub: DurableObjectStub) => {
  for (let i = 0; i < 50; i++) {
    await runDurableObjectAlarm(stub)
    if (await check()) return
    await new Promise((r) => setTimeout(r, 20))
  }
  throw new Error("TeamDO integration sync did not settle")
}
const settleIntegration = (session: string, stub: DurableObjectStub, ok: (v: any) => boolean) =>
  settle(async () => ok((await call("/v1/read", session, { op: "integration.policy.get", params: {} })).json.value), stub)
const settleTeamPolicy = (session: string, stub: DurableObjectStub, ok: (p: any) => boolean) =>
  settle(async () => ok((await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.policy), stub)

describe("SSO/MDM lock notices and release (TeamDO)", () => {
  const sys = (): ReduceContext => ({ principal: { identity: "system:team", kind: "system" }, now: 9_000 + txn, tx: `tx${++txn}`, newId: (p) => `${p}_${String(txn).padStart(20, "0")}` })
  it("records notices by version, lets only admins release, and audits the release", () => {
    let s = baseState()
    const locked = teamDomain.reduce(s, "team.policy.integration_lock", { managed_by: "mdm", version: 2 }, sys())
    if (!locked.ok) throw new Error(locked.message)
    s = locked.state as TeamState
    expect(s.integration_managed_by).toBe("mdm")
    // A late, older notice changes nothing.
    expect(teamDomain.reduce(s, "team.policy.integration_lock", { managed_by: null, version: 1 }, sys())).toMatchObject({ ok: true, changed: false })
    expect(run(s, "team.integration.release_lock", {}, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(run(s, "team.integration.release_lock", {}, ctx(OWNER, { kind: "agent", agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    const released = run(s, "team.integration.release_lock", { reason: "moved IdP" }, ctx())
    if (!released.ok) throw new Error(released.message)
    expect(released.value).toEqual({ released: "mdm" })
    expect(released.outbox?.map((o) => o.kind)).toEqual(["audit.append"])
    expect((released.state as TeamState).integration_release_requested).toBe(1)
    // Without a lock there is nothing to release.
    expect(run(baseState(), "team.integration.release_lock", {}, ctx())).toMatchObject({ ok: false, code: "selector.not_found" })
  })
})

describe("team policy over the API (workerd)", () => {
  it("the team owner sets policy with an idempotency key, members read it, retries replay", async () => {
    const session = await sessionToken("stack-policy-owner")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)

    const before = await call("/v1/read", session, { op: "team.policy.get", params: {} })
    expect(before.json.value.policy).toMatchObject({ version: 0, values: {} })

    const body = {
      op: "team.policy.update",
      params: { changes: [set("computerUse.allowed", false), set("telemetry.level", "crash_only", "default")], expected_version: 0, reason: "pilot" },
      idempotency_key: "policy-1",
      origin: "user"
    }
    const first = await call("/v1/ops", session, body)
    expect(first.json).toMatchObject({ ok: true, value: { version: 1 } })
    expect(first.json.sequence).toBeGreaterThan(0)
    const replay = await call("/v1/ops", session, body)
    expect(replay.json).toMatchObject({ ok: true, replayed: true, transaction: first.json.transaction })

    const read = await call("/v1/read", session, { op: "team.policy.get", params: {} })
    expect(read.json.value.policy.values).toEqual({
      "computerUse.allowed": { value: false, mode: "enforced" },
      "telemetry.level": { value: "crash_only", mode: "default" }
    })
    const hist = await call("/v1/read", session, { op: "team.policy.history", params: {} })
    expect(hist.json.value.versions.map((v: any) => v.version)).toEqual([1])

    const stale = await call("/v1/ops", session, { ...body, idempotency_key: "policy-2" })
    expect(stale.json.error.code).toBe("revision.conflict")
  })

  it("pushes the integration keys to ConnectionDO, which then enforces and locks them", async () => {
    const session = await sessionToken("stack-policy-sync")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    const before = await call("/v1/read", session, { op: "integration.policy.get", params: {} })
    expect(before.json.value).toMatchObject({ source: "default", locked: false })

    const upd = await call("/v1/ops", session, {
      op: "team.policy.update",
      params: { changes: [set("github.repoScope", "installation"), set("github.repoAllowList", ["manaflow-ai/*"])], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    expect(upd.json.ok).toBe(true)
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await settleIntegration(session, stub, (v) => v.source === "team_policy")

    const after = await call("/v1/read", session, { op: "integration.policy.get", params: {} })
    expect(after.json.value).toMatchObject({
      source: "team_policy",
      locked: true,
      github: { scope: "installation", require_org_admin: false, repo_allowlist: ["manaflow-ai/*"] }
    })
    // The projection refuses direct edits: TeamPolicy is the single writer.
    const direct = await call("/v1/ops", session, { op: "integration.policy.set", params: { github: { scope: "linking_user_repos" } }, idempotency_key: crypto.randomUUID() })
    expect(direct.json.error.code).toBe("policy.locked")
  })

  it("a first TeamPolicy version never widens an admin-set integration policy (review HIGH 1)", async () => {
    const session = await sessionToken("stack-policy-seed")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    const narrowed = await call("/v1/ops", session, {
      op: "integration.policy.set",
      params: { github: { require_org_admin: true, repo_allowlist: ["acme/api"] } },
      idempotency_key: crypto.randomUUID()
    })
    expect(narrowed.json.ok).toBe(true)
    // An unrelated key: the integration slice must keep the admin's narrowing.
    const upd = await call("/v1/ops", session, {
      op: "team.policy.update",
      params: { changes: [set("telemetry.level", "off")], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    expect(upd.json.ok).toBe(true)
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    // Wait until TeamDO has seeded (TeamPolicy version 2 copies the admin's values).
    await settleTeamPolicy(session, stub, (p) => p.version >= 2)
    const after = await call("/v1/read", session, { op: "integration.policy.get", params: {} })
    expect(after.json.value.github).toMatchObject({ require_org_admin: true, repo_allowlist: ["acme/api"] })
    // TeamPolicy took over the admin's values (copied before the first push).
    const policy = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.policy
    expect(policy.values["github.requireOrgAdmin"]).toEqual({ value: true, mode: "enforced" })
    expect(policy.values["github.repoAllowList"]).toEqual({ value: ["acme/api"], mode: "enforced" })
  })

  it("after the seed ConnectionDO is locked to TeamPolicy, so there is one writer (review P1-1)", async () => {
    const session = await sessionToken("stack-policy-adopt")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    await call("/v1/ops", session, { op: "integration.policy.set", params: { github: { require_org_admin: true } }, idempotency_key: crypto.randomUUID() })
    await call("/v1/ops", session, { op: "team.policy.update", params: { changes: [set("telemetry.level", "off")], expected_version: 0 }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await settleIntegration(session, stub, (v) => v.source === "team_policy")
    const after = await call("/v1/read", session, { op: "integration.policy.get", params: {} })
    expect(after.json.value).toMatchObject({ source: "team_policy", locked: true, github: { require_org_admin: true } })
    const direct = await call("/v1/ops", session, { op: "integration.policy.set", params: { github: { repo_allowlist: ["acme/x"] } }, idempotency_key: crypto.randomUUID() })
    expect(direct.json.error.code).toBe("policy.locked")
  })

  it("an empty ConnectionDO allow list (deny all) stays deny all after the seed (review P1-2)", async () => {
    const session = await sessionToken("stack-policy-denyall")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    const denied = await call("/v1/ops", session, { op: "integration.policy.set", params: { github: { repo_allowlist: [] } }, idempotency_key: crypto.randomUUID() })
    expect(denied.json.ok).toBe(true)
    await call("/v1/ops", session, { op: "team.policy.update", params: { changes: [set("telemetry.level", "off")], expected_version: 0 }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await settleIntegration(session, stub, (v) => v.source === "team_policy")
    const after = await call("/v1/read", session, { op: "integration.policy.get", params: {} })
    expect(after.json.value.github.repo_allowlist).toEqual([])
    const policy = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.policy
    expect(policy.values["github.repoAllowList"]).toEqual({ value: "none", mode: "enforced" })
  })

  it("an SSO- or MDM-managed ConnectionDO lock always wins over TeamPolicy, and the conflict is reported (E2)", async () => {
    const session = await sessionToken("stack-policy-ssolock")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    const managed = { allowed_providers: null, github: { scope: "linking_user_repos", require_org_admin: true, repo_allowlist: ["acme/api"] } }
    // Nothing writes SSO locks yet: commit one through ConnectionDO's own system op.
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)) as unknown as DurableObjectStub
    // Untyped on purpose: the generic signature over ConnectionDO's RPC types is too deep for tsc.
    const inDO: (stub: DurableObjectStub, fn: (instance: any) => Promise<void>) => Promise<void> = runInDurableObject as any
    await inDO(connections, async (instance) => {
      instance.bind(team)
      const res = instance.submitSystem("integration.policy.apply_managed", { source: "sso", policy: managed, applied_by: "ssoc_test" }, "sso-lock-1")
      expect(res.frames.some((f: any) => f.t === "reject")).toBe(false)
    })
    await call("/v1/ops", session, {
      op: "team.policy.update",
      params: { changes: [set("github.repoScope", "installation"), set("github.repoAllowList", ["acme/web"])], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    const stub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await settle(async () => (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.integration_managed_by === "sso", stub)
    const conn = (await call("/v1/read", session, { op: "integration.policy.get", params: {} })).json.value
    expect(conn).toMatchObject({ source: "sso", locked: true, github: managed.github })
    // The admin's TeamPolicy values stay (they are reported as overridden, not replaced by the copy).
    const read = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value
    expect(read.policy.values["github.repoAllowList"]).toEqual({ value: ["acme/web"], mode: "enforced" })
    expect(read.integration_managed_by).toBe("sso")
  })

  it("ConnectionDO tells TeamDO when an SSO lock appears; an admin release (audited) hands control back to TeamPolicy", async () => {
    const session = await sessionToken("stack-policy-release")
    expect((await call("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() })).json.ok).toBe(true)
    const team = (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.team as string
    await call("/v1/ops", session, {
      op: "team.policy.update",
      params: { changes: [set("github.repoAllowList", ["acme/web"])], expected_version: 0 },
      idempotency_key: crypto.randomUUID(),
      origin: "user"
    })
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
    await settleIntegration(session, teamStub, (v) => v.source === "team_policy")
    // An SSO lock appears in ConnectionDO (nothing writes these yet: its own system op).
    const connStub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)) as unknown as DurableObjectStub
    const inDO: (stub: DurableObjectStub, fn: (instance: any, state: any) => Promise<void>) => Promise<void> = runInDurableObject as any
    await inDO(connStub, async (instance) => {
      const res = instance.submitSystem("integration.policy.apply_managed", { source: "sso", policy: { allowed_providers: null, github: { scope: "linking_user_repos", require_org_admin: true, repo_allowlist: ["acme/api"] } }, applied_by: "ssoc_test" }, "sso-lock-2")
      expect(res.frames.some((f: any) => f.t === "reject")).toBe(false)
    })
    // ConnectionDO's notice reaches TeamDO without any new TeamPolicy version.
    const managedBy = async () => (await call("/v1/read", session, { op: "team.policy.get", params: {} })).json.value.integration_managed_by
    await settle(async () => { await runDurableObjectAlarm(connStub); return (await managedBy()) === "sso" }, teamStub)

    const released = await call("/v1/ops", session, { op: "team.integration.release_lock", params: { reason: "left the IdP" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(released.json.ok).toBe(true)
    await settle(async () => {
      await runDurableObjectAlarm(connStub)
      const conn = (await call("/v1/read", session, { op: "integration.policy.get", params: {} })).json.value
      return conn.source === "team_policy" && (await managedBy()) === null
    }, teamStub)
    const conn = (await call("/v1/read", session, { op: "integration.policy.get", params: {} })).json.value
    expect(conn.github.repo_allowlist).toEqual(["acme/web"])
    await inDO(teamStub as unknown as DurableObjectStub, async (_i: any, state: any) => {
      const ops = state.storage.sql.exec("SELECT payload FROM own_outbox WHERE kind = 'audit.append'").toArray().map((r: any) => JSON.parse(String(r.payload)).op)
      expect(ops).toContain("team.integration.release_lock")
    })
    // Nothing to release now.
    const again = await call("/v1/ops", session, { op: "team.integration.release_lock", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(again.json.ok).toBe(false)
  })
})
