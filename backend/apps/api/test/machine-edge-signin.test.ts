import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { decodeJwt } from "jose"
import { describe, expect, it } from "vitest"
import { authenticate } from "../src/auth.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { post, sessionToken } from "./cloud-bind-support.ts"

/**
 * T17 key_off_machine: the MachineEdgeSignin entrypoint cmux-platform's POST /v1/cloud/machine-identity/token calls
 * once it has verified a machine's edge header. It mints the VM install's bearer without the install key, and only
 * for a live vm install bound to that team and machine under a live vm-self grant.
 */
const MACHINE = "vm_" + "4".repeat(20), OTHER_MACHINE = "vm_" + "5".repeat(20)
const inDO = runInDurableObject as unknown as (s: unknown, f: (i: any) => Promise<void> | void) => Promise<void>

const vmOwner = async (sub: string) => {
  const session = await sessionToken(sub)
  const user = (await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await post("/v1/ops", session, { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: j.x, y: j.y }, kind: "mac", name: "cmux", device_name: "m", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
  expect(reg.body.ok, JSON.stringify(reg.body)).toBe(true)
  const mac = reg.body.value.id as string, macGrant = reg.body.value.grant as string
  const team = personalTeamIdFor(user)
  const ns = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
  const stub = ns.get(ns.idFromName(user))
  const edit = (f: (s: any) => void) => inDO(stub, (i) => f(i.boundEngine.currentState))
  const add = async (classes: Array<string>, extra: Record<string, unknown> = {}) => {
    const id = `inst_vm${crypto.randomUUID().replace(/-/g, "").slice(0, 18)}`, g = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
    await edit((s) => {
      s.installs[id] = { ...s.installs[mac], id, kind: "vm", grant: g, revoked_at: null, bound_team: team, bound_machine: MACHINE, ...extra }
      s.grants[g] = { id: g, grantee: id, op_classes: classes, approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
    })
    return { install: id, grant: g }
  }
  return { user, team, mac, macGrant, edit, add }
}

const signIn = (input: Record<string, unknown>) => (exports as any).MachineEdgeSignin.signIn(input)

describe("machine edge sign-in", { timeout: 60_000 }, () => {
  it("mints the bound vm install's bearer without the edge claim", async () => {
    const o = await vmOwner("edge-signin-ok")
    const vm = await o.add(["read", "mutate-own", "vm-self"])
    const reply = await signIn({ team: o.team, machine: MACHINE, user: o.user, ...vm })
    expect(reply.ok, JSON.stringify(reply)).toBe(true)
    expect(reply.value).toMatchObject({ token_type: "Bearer", user: o.user, team: o.team, install: vm.install, grant: vm.grant })
    const claims = decodeJwt(reply.value.access_token)
    expect([claims.vm, claims.edge, claims.inst, claims.team]).toEqual([true, undefined, vm.install, o.team])
    const p = await authenticate(env as unknown as Env, reply.value.access_token)
    expect(p).toMatchObject({ kind: "install", install_kind: "vm", user: o.user, install: vm.install })
    expect((p as { edge?: boolean }).edge).toBeUndefined()
  })

  it("refuses another machine, team, grant, kind, a revoked install and a grant without vm-self", async () => {
    const o = await vmOwner("edge-signin-refuse")
    const vm = await o.add(["read", "vm-self"])
    const ask = (over: Record<string, unknown>) => signIn({ team: o.team, machine: MACHINE, user: o.user, ...vm, ...over })
    const code = async (over: Record<string, unknown>) => {
      const r = await ask(over)
      return r.ok ? "ok" : `${r.status} ${r.code}`
    }
    expect(await code({})).toBe("ok")
    expect(await code({ machine: OTHER_MACHINE })).toBe("403 auth.forbidden")
    expect(await code({ team: "team_" + "9".repeat(20) })).toBe("403 auth.forbidden")
    expect(await code({ grant: o.macGrant })).toBe("403 auth.forbidden")
    expect(await code({ install: o.mac, grant: o.macGrant })).toBe("403 auth.forbidden")
    expect(await code({ user: "user_99999999999999999999" })).toBe("403 auth.forbidden")
    expect(await code({ team: "not-a-team" })).toBe("400 request.invalid")
    const noSelf = await o.add(["read"])
    expect(await code(noSelf)).toBe("403 auth.forbidden")
    await o.edit((s) => { s.grants[vm.grant] = { ...s.grants[vm.grant], expires_at: Date.now() - 1 } })
    expect(await code({})).toBe("403 auth.forbidden")
    await o.edit((s) => { s.grants[vm.grant] = { ...s.grants[vm.grant], expires_at: null }; s.installs[vm.install] = { ...s.installs[vm.install], revoked_at: 1 } })
    expect(await code({})).toBe("403 auth.forbidden")
  })
})
