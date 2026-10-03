import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { makeUserDomain, type UserState } from "../src/domains/user.ts"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { MAX_REVOKED_ADMIN } from "../src/domains/team-ssh.ts"

/**
 * S4 backend part (plans/cmux-next/team-vm-plan.md S4): when UserDO revokes an install, every
 * unexpired team SSH certificate of that install goes into the team's KRL, durably (UserDO keeps
 * the notice until TeamDO confirms), and the install gets no new certificate.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

interface TeamStub {
  sshOp(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<{ ok: boolean; value?: any; error?: { code: string } }>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
  revokeInstallCerts(entity: string, user: string, install: string): Promise<{ ok: boolean; revoked: Array<number> }>
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
const sshLine = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair
  const pk = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer)
  const s = (v: Uint8Array) => [0, 0, 0, v.length, ...v]
  return `ssh-ed25519 ${b64(Uint8Array.from([...s(new TextEncoder().encode("ssh-ed25519")), ...s(pk)]))} k`
}
/** Serials in the KRL's certificate sections. */
const krlSerials = (krl: string): Array<number> => {
  const b = unb64(krl)
  const dv = new DataView(b.buffer)
  let o = 8 + 4 + 8 + 8 + 8
  const str = () => {
    const n = dv.getUint32(o)
    const v = b.subarray(o + 4, o + 4 + n)
    o += 4 + n
    return v
  }
  str()
  str()
  const out: Array<number> = []
  while (o < b.length) {
    const t = b[o++]!
    const data = str()
    if (t !== 1) continue
    const d = new DataView(data.buffer, data.byteOffset, data.length)
    let p = 4 + d.getUint32(0)
    p += 4 + d.getUint32(p)
    while (p < data.length) {
      p += 1
      const n = d.getUint32(p)
      for (let i = 0; i < n; i += 8) out.push(Number(d.getBigUint64(p + 4 + i)))
      p += 4 + n
    }
  }
  return out.sort((x, y) => x - y)
}

const TEAM = "team_00000000000000000091"
const BOUND = "team_00000000000000000092"
const USER = "user_00000000000000000091"
const INST = "inst_00000000000000000091"
const GRANT = "grant_00000000000000000091"
let txn = 0
const ctx = (p: Principal): ReduceContext => ({ principal: p, now: 5_000, tx: `tx${++txn}`, newId: (x) => `${x}_${String(txn).padStart(20, "0")}` })
const install = (extra: Record<string, unknown> = {}) => ({
  id: INST,
  device: "dev_00000000000000000091",
  kind: "cli",
  name: "cli",
  device_name: "laptop",
  platform: "macos",
  public_jwk: { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) },
  thumbprint: "t",
  grant: GRANT,
  created_at: 1,
  revoked_at: null,
  ...extra
})
const userState = (extra: Record<string, unknown> = {}): UserState =>
  ({
    user: { id: USER, stack_user_id: "s", email: null, display_name: "Lawrence", personal_team: TEAM },
    installs: { [INST]: install(extra) },
    grants: { [GRANT]: { id: GRANT, grantee: INST, op_classes: ["read", "mutate-own"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" } }
  }) as unknown as UserState

describe("install revocation reaches the team SSH KRL (UserDO reducer)", () => {
  const domain = makeUserDomain("test")
  const session: Principal = { identity: `session:${USER}`, kind: "session", user: USER, team: TEAM }
  const system: Principal = { identity: "system:user", kind: "system" }

  it("a revoke records a pending KRL notice for the personal and the bound team; only the owner clears it", () => {
    const r = domain.reduce(userState({ bound_team: BOUND }), "install.revoke", { install: INST }, ctx(session))
    if (!r.ok) throw new Error(r.message)
    expect(r.state.ssh_revoke_pending).toEqual({ [INST]: { user: USER, teams: [TEAM, BOUND], at: 5_000 } })
    expect(domain.authorize!(r.state, "install.ssh_revoke_done", { install: INST }, session)).toBeTruthy()
    expect(domain.authorize!(r.state, "install.ssh_revoke_done", { install: INST }, system)).toBeUndefined()
    // Another owner's system principal (an outbox delivery) cannot clear the notice.
    expect(domain.reduce(r.state, "install.ssh_revoke_done", { install: INST }, ctx({ identity: "system:team:x", kind: "system" }))).toMatchObject({ ok: false, code: "auth.forbidden" })
    const done = domain.reduce(r.state, "install.ssh_revoke_done", { install: INST }, ctx(system))
    if (!done.ok) throw new Error(done.message)
    expect(done.state.ssh_revoke_pending).toEqual({})
  })
})

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@acme.com`, email_verified: true, name: "Lawrence Chen" })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const mutate = async (token: string, op: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ op, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
  })
  return (await res.json()) as any
}

describe("install revocation reaches the team SSH KRL (TeamDO reducer)", () => {
  it("an install revocation from UserDO is never refused for a full revocation list", () => {
    const system: Principal = { identity: "system:team", kind: "system" }
    const full = Object.fromEntries(Array.from({ length: MAX_REVOKED_ADMIN }, (_, i) => [String(i + 1), { valid_before: 9e12, generation: 1 }]))
    const s = { team: { id: TEAM, kind: "personal", display_name: "A" }, members: {}, hosts: {}, ssh_revoked: full } as unknown as TeamState
    const add = (extra: Record<string, unknown>) => teamDomain.reduce(s, "team_vm.ssh_certs_revoked", { serials: [{ serial: 999_999, valid_before: 9e12, generation: 1 }], by: "x", reason: "", ...extra }, ctx(system))
    expect(add({ admin: true })).toMatchObject({ ok: false, code: "team_vm.ssh_revocations_full" })
    expect(add({ admin: true, system: true })).toMatchObject({ ok: true })
  })
})

describe("install revocation reaches the team SSH KRL (workerd)", () => {
  it("UserDO revokes an install; its alarm puts the install's certificates in the KRL; the install gets no new certificate", async () => {
    const token = await sessionToken("stack-ssh-revoke-1")
    const ensured = await mutate(token, "user.ensure", {})
    const user = ensured.value.id as string
    const team = ensured.value.personal_team as string
    const userStub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
    await inDO(userStub, async (instance) => {
      const engine = instance.boundEngine
      const g = { id: GRANT, grantee: INST, op_classes: ["read", "mutate-own"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
      engine.state = { ...engine.currentState, installs: { ...engine.currentState.installs, [INST]: install() }, grants: { ...engine.currentState.grants, [GRANT]: g } }
    })
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as TeamStub
    const p: Principal = { identity: INST, kind: "install", user, team, install: INST, grant: GRANT, grant_classes: ["read", "mutate-own"], install_kind: "cli" }
    const key = await sshLine()
    const op = (pr: Principal) => teamStub.sshOp(team, pr, { op: "team_vm.ssh_cert", params: { public_key: key }, idempotency_key: crypto.randomUUID() })
    const a = (await op(p)).value.serial as number
    const b = (await op(p)).value.serial as number
    const other = (await op({ ...p, identity: "inst_00000000000000000093", install: "inst_00000000000000000093" })).value.serial as number
    expect((await mutate(token, "install.revoke", { install: INST })).ok).toBe(true)
    // The alarm may already be running on its own; drive the same wake work directly (it is idempotent).
    await inDO(userStub, async (instance) => instance.onWake(Date.now()))
    const view = (await teamStub.readOp(team, { identity: `session:${user}`, kind: "session", user, team }, "team_vm.ssh_ca", {})).value
    expect(krlSerials(view.krl)).toEqual([a, b])
    expect(krlSerials(view.krl)).not.toContain(other)
    const pending = await inDO(userStub, async (instance) => instance.boundEngine.currentState.ssh_revoke_pending)
    expect(pending).toEqual({})
    // A request that passed the grant check before the revoke still cannot sign after the notice.
    expect((await op(p)).error?.code).toBe("auth.forbidden")
  })

  it("TeamDO revokes only the certificates of the named user's install", async () => {
    const token = await sessionToken("stack-ssh-revoke-2")
    const ensured = await mutate(token, "user.ensure", {})
    const user = ensured.value.id as string
    const team = ensured.value.personal_team as string
    const teamStub = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)) as unknown as TeamStub
    const p: Principal = { identity: INST, kind: "install", user, team, install: INST, grant: GRANT, grant_classes: ["read", "mutate-own"], install_kind: "cli" }
    const serial = (await teamStub.sshOp(team, p, { op: "team_vm.ssh_cert", params: { public_key: await sshLine() }, idempotency_key: crypto.randomUUID() })).value.serial as number
    expect(await teamStub.revokeInstallCerts(team, "user_00000000000000000099", INST)).toEqual({ ok: true, revoked: [] })
    expect(await teamStub.revokeInstallCerts(team, user, INST)).toEqual({ ok: true, revoked: [serial] })
    // Idempotent: a repeated notice replays the same answer and adds nothing to the KRL.
    const before = (await teamStub.readOp(team, { identity: `session:${user}`, kind: "session", user, team }, "team_vm.ssh_ca", {})).value.krl_version
    expect(await teamStub.revokeInstallCerts(team, user, INST)).toEqual({ ok: true, revoked: [serial] })
    expect((await teamStub.readOp(team, { identity: `session:${user}`, kind: "session", user, team }, "team_vm.ssh_ca", {})).value.krl_version).toBe(before)
  })
})
