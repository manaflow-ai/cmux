import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { verifyChain, type AuditRecord } from "../src/domains/team-audit.ts"
import { complianceFor, devicePolicyFor } from "../src/domains/team-enrollment.ts"
import { teamSubscriberView } from "../src/domains/team-visibility.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"
const INST = "inst_00000000000000000001"
const INST2 = "inst_00000000000000000002"

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const tokenHash = async (token: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))))

const baseState = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "o" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "m" }
  },
  hosts: {}
})

let txn = 0
const ctx = (user = OWNER, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra },
  now: 1_000_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})
const asInstall = (user: string, install: string, email = "a@acme.com") => ctx(user, { kind: "install", install, identity: install, email })

const ok = (r: ReturnType<typeof teamDomain.reduce>) => {
  if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
  return r
}

describe("enrollment and audit reducer (TeamDO)", () => {
  it("hashes tokens like the app (shared vector with CmuxNextSettings ManagedPreferencesTests)", async () => {
    expect(await tokenHash("cmxe_shared_vector_v1")).toBe("gBhFw31wF2LFrvU2l8Xgno2GFgrlOQQkj_hhy9_5fvw")
  })

  it("creates a token without exposing its hash, enrolls a member's install with it, and refuses bad tokens", async () => {
    const h = await tokenHash("cmxe_secret_one")
    let s = baseState()
    const created = ok(teamDomain.reduce(s, "team.enrollment_token.create", { label: "Jamf", token_hash: h, allowed_domains: ["acme.com"] }, ctx()))
    s = created.state as TeamState
    expect(JSON.stringify(created.value)).not.toContain(h)
    expect(JSON.stringify(s.enrollment_tokens)).not.toContain(h)
    expect(teamDomain.reduce(s, "team.enrollment_token.create", { label: "dup", token_hash: h }, ctx())).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(teamDomain.reduce(s, "team.enrollment_token.create", { label: "x", token_hash: await tokenHash("other") }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })

    expect(teamDomain.reduce(s, "team.device.enroll", { token_hash: await tokenHash("wrong") }, asInstall(MEMBER, INST))).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(MEMBER, INST, "m@other.com"))).toMatchObject({ ok: false, code: "policy.invalid" })
    const enrolled = ok(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(MEMBER, INST)))
    s = enrolled.state as TeamState
    expect(s.managed_devices?.[INST]).toMatchObject({ user: MEMBER, via: "token" })
    expect(Object.values(s.enrollment_tokens ?? {})[0]?.uses).toBe(1)
    // Same request again: no change.
    expect(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(MEMBER, INST))).toMatchObject({ ok: true, changed: false })

    const id = Object.keys(s.enrollment_tokens ?? {})[0]!
    s = ok(teamDomain.reduce(s, "team.enrollment_token.revoke", { token: id }, ctx())).state as TeamState
    expect(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(OWNER, INST2))).toMatchObject({ ok: false, code: "policy.invalid" })
    // Explicit acceptance needs no token.
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(OWNER, INST2))).state as TeamState
    expect(s.managed_devices?.[INST2]).toMatchObject({ via: "accept", token: null })
  })

  it("refuses expired tokens, agents, and releases by other members; admins may release", async () => {
    const h = await tokenHash("exp")
    let s = ok(teamDomain.reduce(baseState(), "team.enrollment_token.create", { label: "short", token_hash: h, expires_at: 1_000_000 + txn + 2 }, ctx())).state as TeamState
    txn += 10
    expect(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(MEMBER, INST))).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(teamDomain.reduce(s, "team.device.enroll", {}, ctx(MEMBER, { kind: "agent", install: INST, agent: "agent_x" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(OWNER, INST))).state as TeamState
    expect(teamDomain.reduce(s, "team.device.release", { install: INST }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(ok(teamDomain.reduce(s, "team.device.release", { install: INST }, ctx(OWNER))).state.managed_devices?.[INST]).toBeUndefined()
  })

  it("only admins release a token-enrolled install; agents never release (review, decision a)", async () => {
    const h = await tokenHash("release-rules")
    let s = ok(teamDomain.reduce(baseState(), "team.enrollment_token.create", { label: "MDM", token_hash: h }, ctx())).state as TeamState
    s = ok(teamDomain.reduce(s, "team.device.enroll", { token_hash: h }, asInstall(MEMBER, INST))).state as TeamState
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(MEMBER, INST2))).state as TeamState
    // The member's own MDM-enrolled install: refused (the profile's enrollment is the admin's).
    expect(teamDomain.reduce(s, "team.device.release", { install: INST }, ctx(MEMBER))).toMatchObject({ ok: false, code: "auth.forbidden" })
    // An agent, even of the device's user and on an accepted install: refused.
    expect(teamDomain.reduce(s, "team.device.release", { install: INST2 }, ctx(MEMBER, { kind: "agent", agent: "agent_x", install: INST2 }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    // The member's own accepted install: allowed. An admin: allowed for any.
    expect(teamDomain.reduce(s, "team.device.release", { install: INST2 }, ctx(MEMBER)).ok).toBe(true)
    expect(teamDomain.reduce(s, "team.device.release", { install: INST }, ctx(OWNER)).ok).toBe(true)
  })

  it("status reports drive per-device compliance; members see only their own status (M2)", () => {
    let s = ok(teamDomain.reduce(baseState(), "team.policy.update", { changes: [{ key: "telemetry.level", value: { value: "off", mode: "enforced" } }], expected_version: 0 }, ctx())).state as TeamState
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(MEMBER, INST))).state as TeamState
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(OWNER, INST2))).state as TeamState
    expect(complianceFor(s).devices.map((d) => d.reasons)).toEqual([["no status report"], ["no status report"]])
    s = ok(teamDomain.reduce(s, "team.device.report_status", { policy_version: 1, app_version: "1.0", mdm_keys: ["ui.animationSpeed"], conflicts: [] }, asInstall(MEMBER, INST))).state as TeamState
    s = ok(teamDomain.reduce(s, "team.device.report_status", { policy_version: 0, app_version: "1.0", mdm_keys: [], conflicts: ["ui.animationSpeed"] }, asInstall(OWNER, INST2))).state as TeamState
    const c = complianceFor(s)
    expect(c.devices.map((d) => [d.device.install, d.compliant])).toEqual([[INST, true], [INST2, false]])
    expect(c.devices[1]!.reasons).toEqual(["applied policy v0, current v1", "MDM overrides team policy: ui.animationSpeed"])
    // Same report again: no change. Agents cannot report.
    expect(teamDomain.reduce(s, "team.device.report_status", { policy_version: 1, app_version: "1.0", mdm_keys: ["ui.animationSpeed"], conflicts: [] }, asInstall(MEMBER, INST))).toMatchObject({ ok: true, changed: false })
    expect(teamDomain.reduce(s, "team.device.report_status", { policy_version: 1, app_version: "1.0", mdm_keys: [], conflicts: [] }, ctx(MEMBER, { kind: "agent", agent: "agent_x", install: INST }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    const memberView = teamSubscriberView({ ...s, members: { ...s.members } }, { identity: `user:${MEMBER}`, user: MEMBER, kind: "session" })
    expect(Object.keys(memberView.device_status ?? {})).toEqual([INST])
  })

  it("every admin action appends one record to a hash chain that verifies, and tampering breaks it", async () => {
    let s = baseState()
    const records: Array<AuditRecord> = []
    const step = (op: string, params: unknown, c = ctx()) => {
      const r = ok(teamDomain.reduce(s, op, params, c))
      s = r.state as TeamState
      for (const o of r.outbox ?? []) if (o.kind === "audit.append") records.push(o.payload as AuditRecord)
    }
    step("team.policy.update", { changes: [{ key: "telemetry.level", value: { value: "off", mode: "enforced" } }], expected_version: 0, reason: "privacy" })
    step("team.enrollment_token.create", { label: "Kandji", token_hash: await tokenHash("t2") })
    step("team.device.enroll", {}, asInstall(OWNER, INST))
    step("team.policy.rollback", { version: 0, expected_version: 1 })
    // A no-op writes no record.
    step("team.policy.update", { changes: [{ key: "telemetry.level", value: null }], expected_version: 2 })
    expect(records.map((r) => r.op)).toEqual(["team.policy.update", "team.enrollment_token.create", "team.device.enroll", "team.policy.rollback"])
    expect(records.map((r) => r.n)).toEqual([1, 2, 3, 4])
    expect(records.every((r) => !JSON.stringify(r).includes("@"))).toBe(true)
    expect(verifyChain(records)).toBe(true)
    expect(verifyChain([records[0]!, records[2]!, records[3]!])).toBe(false)
    expect(verifyChain([{ ...records[0]!, summary: "edited" }, ...records.slice(1)])).toBe(false)
  })

  it("the device policy read carries cmux.json settings from device.settings, and feature keys separately, only for a managed install", () => {
    let s = ok(
      teamDomain.reduce(
        baseState(),
        "team.policy.update",
        {
          changes: [
            { key: "device.settings", value: { value: { "ui.animationSpeed": { value: "off", mode: "enforced" }, "layout.stripScrollbar": { value: "always", mode: "default" } }, mode: "enforced" } },
            { key: "telemetry.level", value: { value: "crash_only", mode: "enforced" } },
            { key: "github.repoScope", value: { value: "installation", mode: "enforced" } }
          ],
          expected_version: 0
        },
        ctx()
      )
    ).state as TeamState
    expect(devicePolicyFor(s, INST)).toEqual({ managed: false, version: 1, defaults: {}, enforced: {}, features: {} })
    s = ok(teamDomain.reduce(s, "team.device.enroll", {}, asInstall(OWNER, INST))).state as TeamState
    expect(devicePolicyFor(s, INST)).toEqual({
      managed: true,
      version: 1,
      defaults: { "layout.stripScrollbar": "always" },
      enforced: { "ui.animationSpeed": "off" },
      features: { "telemetry.level": { value: "crash_only", mode: "enforced" } }
    })
    // Keys must look like cmux.json key paths.
    expect(teamDomain.reduce(baseState(), "team.policy.update", { changes: [{ key: "device.settings", value: { value: { appearance: { value: {}, mode: "enforced" } }, mode: "enforced" } }], expected_version: 0 }, ctx())).toMatchObject({ ok: false, code: "policy.invalid" })
  })
})

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@acme.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}

const call = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })

const installToken = async (session: string, user: string) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(new Uint8Array(sig)) })
  return { install, jwt: tok.json.access_token as string }
}

describe("enrollment over the API (workerd)", () => {
  it("an MDM token enrolls the signed-in install, which then reads its device policy; audit rows are in the outbox", async () => {
    const session = await sessionToken("stack-enroll-owner")
    const user = (await op(session, "user.ensure", {})).json.value.id as string
    const { install, jwt } = await installToken(session, user)

    const token = "cmxe_" + b64u(crypto.getRandomValues(new Uint8Array(32)))
    const created = await op(session, "team.enrollment_token.create", { label: "Jamf prod", token_hash: await tokenHash(token), allowed_domains: ["acme.com"] })
    expect(created.json.ok).toBe(true)
    expect(JSON.stringify(created.json)).not.toContain(await tokenHash(token))
    await op(session, "team.policy.update", { changes: [{ key: "device.settings", value: { value: { "ui.animationSpeed": { value: "off", mode: "enforced" } }, mode: "enforced" } }], expected_version: 0 })

    const before = await call("/v1/read", jwt, { op: "team.device.policy", params: {} })
    expect(before.json.value).toMatchObject({ managed: false, enforced: {} })
    const enrolled = await op(jwt, "team.device.enroll", { token_hash: await tokenHash(token) })
    expect(enrolled.json).toMatchObject({ ok: true, value: { install, via: "token" } })
    const after = await call("/v1/read", jwt, { op: "team.device.policy", params: {} })
    expect(after.json.value).toMatchObject({ managed: true, version: 1, enforced: { "ui.animationSpeed": "off" } })

    const list = await call("/v1/read", session, { op: "team.enrollment_token.list", params: {} })
    expect(list.json.value.tokens[0]).toMatchObject({ label: "Jamf prod", uses: 1 })
    expect(list.json.value.tokens[0].token_hash).toBeUndefined()

    const team = after.json.value.team as string
    await runInDurableObject(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (_i, state) => {
      const rows = state.storage.sql.exec("SELECT kind, payload FROM own_outbox WHERE kind = 'audit.append' ORDER BY id").toArray()
      expect(rows.map((r) => (JSON.parse(String(r.payload)) as AuditRecord).op)).toEqual(["team.enrollment_token.create", "team.policy.update", "team.device.enroll"])
      expect(verifyChain(rows.map((r) => JSON.parse(String(r.payload)) as AuditRecord))).toBe(true)
    })
  })
})
