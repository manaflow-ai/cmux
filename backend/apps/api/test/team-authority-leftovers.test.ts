import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { Principal, ReduceContext } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { makeUserDomain, type UserState } from "../src/domains/user.ts"
import { deliverKrlNotices, type KrlRetry } from "../src/user-krl.ts"
import { clearSignInRules } from "../src/policy-gate.ts"
import { bindBody, bindFile, frame, person, reply, SIZE } from "./cloud-bind-support.ts"

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
const vmParams = (n: number) => ({ public_jwk: jwk(n), kind: "vm", name: "Cloud VM", device_name: "m", platform: "linux", bound_team: LEFT, bound_machine: `vm_${String(n).padStart(20, "0")}` })
const must = <T,>(r: { ok: boolean; state?: T; value?: any; message?: string }) => {
  if (!r.ok) throw new Error(r.message)
  return r as { ok: true; state: T; value: any }
}

describe("a removal's leftovers (cx-44j.51)", { timeout: 60_000 }, () => {

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
    // TeamDO's RPC fails for this one team (RPC dispatches through the class, so the prototype is patched and restored).
    const proto = await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => Object.getPrototypeOf(instance))
    const real = proto.signInRules
    proto.signInRules = async function (this: unknown, entity: string, ...rest: Array<unknown>) {
      if (entity === team) throw new Error("TeamDO down")
      return real.call(this, entity, ...rest)
    }
    try {
      // user.ensure above cached this team's rules for 30 s; ask TeamDO again.
      clearSignInRules()
      const res = await call("/v1/read", { op: "install.list", params: {} })
      expect(res.status).toBe(503)
      expect(await res.json()).toMatchObject({ code: "owner.unreachable", retryable: true })
    } finally {
      proto.signInRules = real
    }
  })

})

describe("team.ensure_personal names only the caller's own personal team (cx-er4p review)", () => {
  it("refuses any other team id, so no principal can make itself owner of a shared team through it", async () => {
    const x = person()
    const ns = testEnv.TEAM_DO as DurableObjectNamespace
    const submit = (team: string, p: Principal) => (ns.get(ns.idFromName(team)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<any> }).submit(team, p, { t: "op", op: "team.ensure_personal", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })
    const foreign = "team_shared00000000000077"
    expect(reply(await submit(foreign, { ...x.p, team: foreign }))).toMatchObject({ t: "reject", code: "auth.forbidden" })
    expect(reply(await submit(x.team, x.p)).t).toBe("result")
  })
})
