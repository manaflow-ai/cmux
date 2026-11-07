import { runInDurableObject } from "cloudflare:test"
import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { authorizeDefaultMachine, defaultHandId, type DefaultHandScope } from "../src/chief-default-hand.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { handStub } from "../src/hand-api.ts"
import type { HandDO } from "../src/hand-do.ts"
import type { Env } from "../src/env.ts"

const testEnv = env as unknown as Env
const scopeFor = (suffix: string): DefaultHandScope => {
  const owner = `user_hand_${suffix}`
  return { owner, chief: `agent_hand_${suffix}`, team: personalTeamIdFor(owner), workspace: `chief-default-${owner}`, machine: `machine_${suffix}`, provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: `inst_${suffix}` }
}

const fixture = (scope: DefaultHandScope) => {
  const binding = { workspace: scope.workspace, team: scope.team, machine: scope.machine, provider: scope.provider, connection_machine: scope.connection_machine, install: scope.install }
  const chief = { id: scope.chief, owner_user: scope.owner, archived_at: null as string | null, brain_place: null, cloud_machine: binding }
  const install = { id: scope.install, kind: "vm", grant: "grant_default", revoked_at: null as number | null, bound_team: scope.team, bound_machine: scope.connection_machine }
  const grant = { id: install.grant, grantee: install.id, revoked_at: null as number | null, expires_at: null as number | null, op_classes: ["vm-self"] }
  const machine = { creator: scope.owner, status: "running" }
  let currentCarrier = true
  let refusal = "auth.forbidden"
  const fake = {
    ...testEnv,
    USER_DO: { idFromName: (x: string) => x, get: () => ({ readOp: async (_entity: string, _principal: unknown, op: string) => ({ ok: true, value: op === "chief.list" ? { chiefs: [chief] } : { installs: [install], grants: [grant] } }) }) },
    CLOUD_DO: { idFromName: (x: string) => x, get: () => ({ readOp: async () => currentCarrier ? { ok: true, value: { machine } } : { ok: false, code: refusal, message: "carrier read refused" } }) },
  } as unknown as Env
  return { fake, chief, install, grant, machine, replaceCarrier: () => { currentCarrier = false; refusal = "auth.forbidden" }, unavailableCarrier: () => { currentCarrier = false; refusal = "owner.unreachable" } }
}

describe("default Chief hand authority", () => {
  it("requires the fixed personal default scope, live VM grant and current carrier", async () => {
    const scope = scopeFor("authority")
    const f = fixture(scope)
    await expect(authorizeDefaultMachine(f.fake, scope)).resolves.toBeDefined()
    await expect(authorizeDefaultMachine(f.fake, { ...scope, team: "team_other" })).rejects.toThrow("invalid_scope")
    f.grant.expires_at = Date.now() - 1
    await expect(authorizeDefaultMachine(f.fake, scope)).rejects.toThrow("install_revoked")
    f.grant.expires_at = null
    f.install.revoked_at = Date.now()
    await expect(authorizeDefaultMachine(f.fake, scope)).rejects.toThrow("install_revoked")
    f.install.revoked_at = null
    f.replaceCarrier()
    await expect(authorizeDefaultMachine(f.fake, scope)).rejects.toThrow("carrier_changed")
  })

  it("registers an exact guest key once and never restores a removed grant or revoked hand", async () => {
    const scope = scopeFor("registration")
    const { fake } = fixture(scope)
    const hand = defaultHandId(scope)
    const stub = handStub(testEnv, hand)
    const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: HandDO) => Promise<T>) => Promise<T>
    await inDO(stub, async (instance) => {
      const object = instance as unknown as { env: Env }
      const original = object.env
      object.env = fake
      try {
        expect(await instance.ensureDefault(scope, "a".repeat(64))).toEqual({ ok: true, hand })
        expect(await instance.ensureDefault(scope, "a".repeat(64))).toEqual({ ok: true, hand })
        expect(await instance.ensureDefault(scope, "b".repeat(64))).toMatchObject({ ok: false, code: "hand.default_conflict" })
        expect(await instance.ensureDefault({ ...scope, install: "inst_other" }, "a".repeat(64))).toMatchObject({ ok: false, code: "validation.invalid" })
        expect(await instance.info({ kind: "chief", user: scope.owner, agent: "another_chief" })).toMatchObject({ ok: false, error: { code: "hand.no_grant" } })
        await instance.setGrants([], { agent: "another_chief", on: false })
        expect(await instance.ensureDefault(scope, "a".repeat(64))).toEqual({ ok: true, hand })
        await instance.setGrants([], { agent: scope.chief, on: false })
        expect(await instance.ensureDefault(scope, "a".repeat(64))).toMatchObject({ ok: false, code: "hand.no_grant" })
        await instance.revoke({ kind: "owner", user: scope.owner })
        expect(await instance.ensureDefault(scope, "a".repeat(64))).toMatchObject({ ok: false, code: "hand.revoked" })
      } finally { object.env = original }
    })
  })

  it("distinguishes a temporary authority read failure from a definite carrier refusal", async () => {
    const scope = scopeFor("transient"), f = fixture(scope)
    f.unavailableCarrier()
    await expect(authorizeDefaultMachine(f.fake, scope)).rejects.toThrow("carrier_unavailable")
    f.replaceCarrier()
    await expect(authorizeDefaultMachine(f.fake, scope)).rejects.toThrow("carrier_changed")
  })
})
