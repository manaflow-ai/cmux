import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { makeUserDomain, type UserState } from "../src/domains/user.ts"
import { deliverKrlNotices, type KrlRetry } from "../src/user-krl.ts"

/**
 * cx-44j.51: what a team removal leaves behind. (1) A machine created under the team's SSO and bound
 * after its creator left that team gets no sso_team from it. (2) An SSO gate RPC failure answers a
 * retryable owner.unreachable (503), not a 500. (3) A KRL notice is confirmed per team, and only the
 * teams still missing are asked again.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

const USER = "user_00000000000000000071"
const TEAM = "team_00000000000000000071"
const LEFT = "team_00000000000000000072"
let txn = 0
const ctx = (p: Principal): ReduceContext => ({ principal: p, now: 5_000 + txn, tx: `tx${++txn}`, newId: (x) => `${x}_${String(txn).padStart(20, "0")}` })
const domain = makeUserDomain("test")
const base = { user: { id: USER, stack_user_id: "s", email: null, display_name: "Ann", personal_team: TEAM }, installs: {}, grants: {} } as unknown as UserState
const jwk = (n: number) => ({ kty: "EC", crv: "P-256", x: String(n).padStart(43, "x"), y: "y".repeat(43) })
const vmParams = (n: number) => ({ public_jwk: jwk(n), kind: "vm", name: "Cloud VM", device_name: "m", platform: "linux", bound_team: LEFT, bound_machine: `cm_${String(n).padStart(20, "0")}` })
const must = <T,>(r: { ok: boolean; state?: T; value?: any; message?: string }) => {
  if (!r.ok) throw new Error(r.message)
  return r as { ok: true; state: T; value: any }
}

describe("a removal's leftovers (cx-44j.51)", { timeout: 60_000 }, () => {
  it("a VM bound after its creator left the team does not get the team's SSO; a new SSO sign-in through it restores it", () => {
    const left = must(domain.reduce(base, "user.team_left", { team: LEFT, at: 4_000 }, ctx({ identity: `system:team:${LEFT}`, kind: "system" })))
    // CloudDO registers the VM install with the machine's stored creator_sso_team.
    const cloud: Principal = { identity: `system:cloud:${LEFT}`, kind: "system", user: USER, team: LEFT, sso_team: LEFT }
    const vm = must(domain.reduce(left.state, "install.register_server", vmParams(1), ctx(cloud)))
    expect(vm.value.sso_team).toBeUndefined()
    // The person signs in through the team's SSO again: their next install carries it, and so does a later VM.
    const session: Principal = { identity: `session:${USER}`, kind: "session", user: USER, team: TEAM, stack_user_id: "s", sso_team: LEFT }
    const fresh = must(domain.reduce(vm.state, "install.register", { public_jwk: jwk(2), kind: "cli", name: "cli", device_name: "laptop", platform: "macos" }, ctx(session)))
    expect(fresh.value.sso_team).toBe(LEFT)
    const vm2 = must(domain.reduce(fresh.state, "install.register_server", vmParams(3), ctx(cloud)))
    expect(vm2.value.sso_team).toBe(LEFT)
  })

  it("an SSO gate RPC failure answers a retryable owner.unreachable, never a 500", async () => {
    const sub = `leftover-${crypto.randomUUID().slice(0, 8)}`
    const token = await new SignJWT({ email: `${sub}@example.com`, name: sub })
      .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
      .setAudience(testEnv.STACK_PROJECT_ID)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
    const call = (path: string, body: unknown) => worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
    const ensured = (await (await call("/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).json()) as any
    const team = ensured.value.personal_team as string
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
      instance.signInRules = async () => {
        throw new Error("TeamDO down")
      }
    })
    const res = await call("/v1/read", { op: "install.list", params: {} })
    expect(res.status).toBe(503)
    expect(await res.json()).toMatchObject({ code: "owner.unreachable", retryable: true })
  })

  it("confirms a KRL notice team by team and asks again only the teams still missing", async () => {
    const asked: Array<string> = []
    let down = true
    const fakeEnv = {
      TEAM_DO: {
        idFromName: (t: string) => t,
        get: (t: string) => ({
          revokeInstallCerts: async () => {
            asked.push(t)
            if (t === "team_b" && down) throw new Error("down")
            return { ok: true, revoked: [] }
          }
        })
      }
    }
    const state = { ssh_revoke_pending: { inst_1: { user: USER, teams: ["team_a", "team_b", "team_c"], at: 1 } } } as unknown as UserState
    const confirmed: Array<{ install: string; teams: ReadonlyArray<string> }> = []
    const retry: KrlRetry = { at: null, attempts: 0 }
    await deliverKrlNotices(fakeEnv as any, state, retry, 10, (install, _at, teams) => confirmed.push({ install, teams }))
    expect(confirmed).toEqual([{ install: "inst_1", teams: ["team_a", "team_c"] }])
    expect(retry.at).not.toBeNull()
    // The reducer keeps only team_b pending.
    const after = must(domain.reduce({ ...base, ...state } as UserState, "install.ssh_revoke_done", { install: "inst_1", teams: ["team_a", "team_c"] }, ctx({ identity: "system:user", kind: "system" })))
    expect(after.state.ssh_revoke_pending?.inst_1?.teams).toEqual(["team_b"])
    asked.length = 0
    down = false
    await deliverKrlNotices(fakeEnv as any, after.state, { at: null, attempts: 1 }, 10_000, (install, _at, teams) => confirmed.push({ install, teams }))
    expect(asked).toEqual(["team_b"])
    const done = must(domain.reduce(after.state, "install.ssh_revoke_done", { install: "inst_1", teams: ["team_b"] }, ctx({ identity: "system:user", kind: "system" })))
    expect(done.state.ssh_revoke_pending).toEqual({})
  })
})
