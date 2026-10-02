import { env, exports } from "cloudflare:workers"
import type { ReduceContext } from "@cmux/ownership"
import { policyKeys } from "@cmux/protocol"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { currentPolicy, POLICY_HISTORY_LIMIT } from "../src/domains/team-policy.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
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

  it("refuses lockouts: enforced SSO without a connection, allow_list scope without repos", () => {
    const s = baseState()
    expect(run(s, "team.policy.update", { changes: [set("sso.enforce", true)], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    // A default (recommended) value cannot lock anyone out.
    expect(run(s, "team.policy.update", { changes: [set("sso.enforce", true, "default")], expected_version: 0 }).ok).toBe(true)
    expect(run(s, "team.policy.update", { changes: [set("github.repoScope", "allow_list")], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    const ok = run(s, "team.policy.update", { changes: [set("github.repoScope", "allow_list"), set("github.repoAllowList", ["manaflow-ai/*"])], expected_version: 0 })
    expect(ok.ok).toBe(true)
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
})
