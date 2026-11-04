import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import type { Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { DEFAULT_CHIEF_BIND, DEFAULT_CHIEF_ENSURE, DEFAULT_CHIEF_PROVISION, HOSTED_DEFAULT_KEY, defaultChiefIdentity, defaultChiefWorkspace } from "../src/domains/user-chief-default.ts"
import { personalTeamIdFor, userDomain, type UserState } from "../src/domains/user.ts"
import { deliverSignupChief, ensureChiefMachine, type DefaultMachinePlatform } from "../src/user-chief-provision.ts"
import type { TargetItem } from "../src/do-outbox.ts"
import { fireAlarm, quiesce } from "./setup/alarm.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"
import { bindFile, cloudStub, frame, reply, SIZE, vmKey, WG_KEY, DAEMON } from "./cloud-bind-support.ts"

const USER = "user_00000000000000000001"
const TEAM = personalTeamIdFor(USER)
const VM = "vm_00000000000000000001"
const INSTALL = "inst_00000000000000000001"
const profile = { id: USER, stack_user_id: "signup-stack-user", email: "signup@example.com", email_verified: true, display_name: "New User", personal_team: TEAM }
const session: Principal = { identity: `user:${USER}`, kind: "session", user: USER, team: TEAM, stack_user_id: profile.stack_user_id, email: profile.email, email_verified: true, display_name: profile.display_name }
const context = (principal: Principal = { identity: defaultChiefIdentity(USER), kind: "system" }, tx = "signup-tx"): ReduceContext => ({ principal, tx, now: 1_000_000, newId: (prefix) => `${prefix}_00000000000000000001` })
const existing = (): UserState => ({ ...userDomain.initial(), user: profile })
const decided = (r: ReduceResult<UserState>) => {
  if (!r.ok) throw new Error(`${r.code}: ${r.message}`)
  return r
}
const ensured = () => decided(userDomain.reduce(existing(), DEFAULT_CHIEF_ENSURE, {}, context())).state
const machineState = (state = ensured()): UserState => ({
  ...state,
  installs: { [INSTALL]: { id: INSTALL, device: "dev_00000000000000000001", kind: "vm", name: "Cloud", device_name: "Cloud", platform: "linux", public_jwk: { kty: "EC", crv: "P-256", x: "x".repeat(43), y: "y".repeat(43) }, thumbprint: "vm-key", grant: "grant_00000000000000000001", created_at: 1, revoked_at: null, bound_team: TEAM, bound_machine: VM } },
  grants: { grant_00000000000000000001: { id: "grant_00000000000000000001", grantee: INSTALL, op_classes: ["vm-self"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" } }
})
const binding = { workspace: defaultChiefWorkspace(USER), team: TEAM, machine: "logical-machine", provider: "freestyle", connection_machine: VM, install: INSTALL }
const platformValue = () => ({ workspace: defaultChiefWorkspace(USER), team: TEAM, connectionMachine: VM, machine: { id: "logical-machine", provider: "freestyle", creator: USER, visibility: "private", kind: "user" } })
const platform = (value = platformValue()): DefaultMachinePlatform => ({ ensureDefaultMachine: async () => ({ ok: true, value }) })

describe("signup default Chief", () => {
  it("enqueues creation and machine provisioning only on the first user.ensure", () => {
    const first = decided(userDomain.reduce(userDomain.initial(), "user.ensure", {}, context(session)))
    expect(first.outbox?.filter((o) => o.target?.class === "UserDO")).toEqual([
      { kind: DEFAULT_CHIEF_ENSURE, entity: HOSTED_DEFAULT_KEY, payload: {}, target: { class: "UserDO", name: USER } },
      { kind: DEFAULT_CHIEF_PROVISION, entity: `chief-default-machine:${USER}`, payload: {}, target: { class: "UserDO", name: USER } }
    ])
    const again = decided(userDomain.reduce(first.state, "user.ensure", {}, context(session, "again")))
    expect(again.changed).toBe(false)
    expect(again.outbox).toEqual([])
    const renamed = decided(userDomain.reduce(first.state, "user.ensure", {}, context({ ...session, display_name: "Renamed" })))
    expect(renamed.outbox?.map((o) => o.kind)).toEqual(["user.upsert"])
  })

  it("creates one hosted default and its conversation without a client Chief call; retries keep it", () => {
    const made = decided(userDomain.reduce(existing(), DEFAULT_CHIEF_ENSURE, {}, context()))
    const id = made.state.hosted_default!
    expect(made.state.chiefs?.[id]).toMatchObject({ owner_user: USER, display_name: "Chief", is_default: true, brain: "cloud", brain_place: null })
    expect(made.outbox?.map((o) => o.kind)).toEqual(["mux.bind", "conversation.create"])
    const replay = decided(userDomain.reduce(made.state, DEFAULT_CHIEF_ENSURE, {}, context(undefined, "another-tx")))
    expect(replay.changed).toBe(false)
    expect(Object.keys(replay.state.chiefs ?? {})).toEqual([id])
    const raced = decided(userDomain.reduce(made.state, "chief.create", { display_name: "Chief", is_default: true }, { ...context(session), idempotencyKey: HOSTED_DEFAULT_KEY }))
    expect(raced.changed).toBe(false)
    expect((raced.value as { id: string }).id).toBe(id)
    expect(Object.keys(raced.state.chiefs ?? {})).toEqual([id])
    const removed: UserState = { ...made.state, chiefs: {} }
    expect(decided(userDomain.reduce(removed, DEFAULT_CHIEF_ENSURE, {}, context())).value).toBeNull()
    expect(decided(userDomain.reduce(removed, DEFAULT_CHIEF_ENSURE, {}, context())).state.chiefs).toEqual({})
  })

  it("adopts a hosted Chief when a client wins the race, preserving its chosen name", () => {
    const client = decided(userDomain.reduce(existing(), "chief.create", { display_name: "Ada" }, context(session)))
    const adopted = decided(userDomain.reduce(client.state, DEFAULT_CHIEF_ENSURE, {}, context()))
    expect(Object.keys(adopted.state.chiefs ?? {})).toHaveLength(1)
    expect(adopted.state.chiefs?.[adopted.state.hosted_default!]?.display_name).toBe("Ada")
    expect(adopted.outbox).toBeUndefined()
  })

  it("refuses client, agent and other-owner provisioning, in authorization and reducer", () => {
    for (const principal of [session, { ...session, kind: "agent" as const, agent: "agent_other" }, { identity: "system:user:someone-else", kind: "system" as const }, { identity: "system:cloud", kind: "system" as const }]) {
      expect(userDomain.authorize?.(existing(), DEFAULT_CHIEF_ENSURE, {}, principal)?.code).toBe("auth.forbidden")
      expect(userDomain.reduce(existing(), DEFAULT_CHIEF_ENSURE, {}, context(principal))).toMatchObject({ ok: false, code: "auth.forbidden" })
      expect(userDomain.reduce(machineState(), DEFAULT_CHIEF_BIND, binding, context(principal))).toMatchObject({ ok: false, code: "auth.forbidden" })
    }
  })

  it("binds only the same user's live VM install and never widens its grant or moves its hosted brain", () => {
    const state = machineState()
    const bound = decided(userDomain.reduce(state, DEFAULT_CHIEF_BIND, binding, context()))
    expect(bound.state.chiefs?.[state.hosted_default!]).toMatchObject({ brain_place: null, cloud_machine: binding })
    expect(bound.state.grants).toEqual(state.grants)
    expect(decided(userDomain.reduce(bound.state, DEFAULT_CHIEF_BIND, binding, context())).changed).toBe(false)
    expect(userDomain.reduce(bound.state, DEFAULT_CHIEF_BIND, { ...binding, machine: "replacement" }, context())).toMatchObject({ ok: false, code: "auth.forbidden" })
    for (const bad of [{ ...binding, team: "team_other" }, { ...binding, workspace: "another-workspace" }, { ...binding, install: "inst_other" }, { ...binding, connection_machine: "vm_00000000000000000002" }]) {
      expect(userDomain.reduce(state, DEFAULT_CHIEF_BIND, bad, context())).toMatchObject({ ok: false, code: "validation.invalid" })
    }
    for (const changed of [
      { ...state, installs: { [INSTALL]: { ...state.installs[INSTALL]!, revoked_at: 1 } } },
      { ...state, grants: { grant_00000000000000000001: { ...state.grants.grant_00000000000000000001!, expires_at: 1 } } },
      { ...state, installs: { [INSTALL]: { ...state.installs[INSTALL]!, kind: "daemon" as const } } }
    ]) expect(userDomain.reduce(changed, DEFAULT_CHIEF_BIND, binding, context())).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("retries admission/registration outages and rejects cross-account platform replies", async () => {
    const state = machineState()
    expect(await ensureChiefMachine(platform(), USER, () => state, () => context().now)).toEqual(binding)
    await expect(ensureChiefMachine(undefined, USER, () => state)).rejects.toMatchObject({ retryable: true })
    await expect(ensureChiefMachine(platform(), USER, existing)).rejects.toMatchObject({ message: "chief.provision.machine_binding_pending", retryable: true })
    await expect(ensureChiefMachine({ ensureDefaultMachine: async () => { throw new Error("transport") } }, USER, () => state)).rejects.toMatchObject({ retryable: true })
    await expect(ensureChiefMachine({ ensureDefaultMachine: async () => ({ ok: false, code: "budget.exhausted", message: "not admitted", retryable: false }) }, USER, () => state)).rejects.toMatchObject({ message: "budget.exhausted", retryable: false })
    for (const bad of [
      { ...platformValue(), team: "team_other" },
      { ...platformValue(), workspace: "other" },
      { ...platformValue(), machine: { ...platformValue().machine, creator: "user_other" } },
      { ...platformValue(), machine: { ...platformValue().machine, kind: "fleet" } },
      { ...platformValue(), machine: { ...platformValue().machine, visibility: "team" } }
    ]) await expect(ensureChiefMachine(platform(bad), USER, () => state)).rejects.toMatchObject({ message: "chief.provision.invalid_machine", retryable: false })
  })

  it("a partial outbox delivery resumes after VM registration without creating a second Chief", async () => {
    let state = existing()
    const items = [
      { id: 1, op: DEFAULT_CHIEF_ENSURE, key: HOSTED_DEFAULT_KEY, params: {} },
      { id: 2, op: DEFAULT_CHIEF_PROVISION, key: `chief-default-machine:${USER}`, params: {} }
    ]
    const host = {
      platform: platform(),
      current: () => state,
      activate: async () => ({ ok: true as const }),
      deliver: async (batch: ReadonlyArray<TargetItem>) => {
        for (const item of batch) state = decided(userDomain.reduce(state, item.op, item.params, context())).state
        return { done: batch.map((item) => item.id) }
      },
      bind: (machine: typeof binding) => {
        state = decided(userDomain.reduce(state, DEFAULT_CHIEF_BIND, machine, context())).state
        return { frames: [{ t: "result" as const, tx: "bind", idempotency_key: "bind", value: machine, revision: "1", replayed: false }] }
      }
    }
    await expect(deliverSignupChief(USER, `user:${USER}`, items, host)).rejects.toMatchObject({ retryable: true })
    const chief = state.hosted_default
    state = machineState(state)
    expect(await deliverSignupChief(USER, `user:${USER}`, items, host)).toEqual({ done: [1, 2] })
    expect(Object.keys(state.chiefs ?? {})).toEqual([chief])
    expect(state.chiefs?.[chief!]?.cloud_machine).toEqual(binding)
    await expect(deliverSignupChief(USER, "user:other", items, host)).rejects.toMatchObject({ retryable: false })
    await expect(deliverSignupChief(USER, `user:${USER}`, [{ ...items[1]!, params: { machine: "foreign" } }], host)).rejects.toMatchObject({ retryable: false })
  })
})

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

describe("signup outbox integration", () => {
  it("first signup creates and binds its Chief on the server, without chief.create or a machine client request", async () => {
    const user = cloudTestUser(188), team = personalTeamIdFor(user)
    let carrier: string | undefined
    const namespace = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
    const stub = namespace.get(namespace.idFromName(user))
    await runInDurableObject(stub, async (i) => {
      i.signupMachineReady = false
      let machine: Promise<Awaited<ReturnType<DefaultMachinePlatform["ensureDefaultMachine"]>>> | undefined
      i.signupPlatform = () => ({ ensureDefaultMachine: async (owner: string) => {
        if (owner !== user) throw new Error("wrong owner")
        if (!i.signupMachineReady) throw new Error("machine is still booting")
        return machine ??= (async () => {
          const cloud = cloudStub(team)
          const created = reply(await cloud.submit(team, { identity: `session:${user}`, kind: "session", user, team }, frame("cloud.machine.create", { size: SIZE })))
          if (created.t !== "result") throw new Error(JSON.stringify(created))
          carrier = created.value.machine.id as string
          const file = await bindFile(cloud, carrier), key = await vmKey()
          const bound = await cloud.bindMachine(team, { team, machine: carrier, bind_token: file.json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
          if (!bound.ok) throw new Error(JSON.stringify(bound))
          return { ok: true as const, value: { workspace: defaultChiefWorkspace(user), team, connectionMachine: carrier, machine: { ...platformValue().machine, creator: user } } }
        })()
      } })
    })
    const request = { ...session, identity: `user:${user}`, user, team, stack_user_id: "signup-integration" }
    const result = await (stub as unknown as { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string }> }> }).submit(user, request, { t: "op", op: "user.ensure", params: {}, idempotency_key: "signup", origin: "user" })
    expect(result.frames.some((f) => f.t === "result")).toBe(true)
    await fireAlarm(stub)
    const pendingId = await runInDurableObject(stub, async (i, s) => {
      await quiesce(i, s)
      const state = i.boundEngine.currentState as UserState
      expect(state.chiefs?.[state.hosted_default!]?.cloud_machine).toBeUndefined()
      return state.hosted_default!
    })
    const brains = (env as unknown as { CHIEF_BRAIN_DO: DurableObjectNamespace }).CHIEF_BRAIN_DO
    const brain = brains.get(brains.idFromName(pendingId)) as unknown as {
      status(): Promise<{ config: { enabled: boolean } }>
      configure(agent: string, owner: string, patch: { enabled: boolean }): Promise<{ ok: boolean }>
      admit(agent: string, owner: string, turn: boolean): Promise<{ ok: boolean; reason?: string; machine?: { binding: { connection_machine: string } } }>
    }
    expect((await brain.status()).config.enabled).toBe(true)
    expect(await brain.admit(pendingId, user, true)).toEqual({ ok: false, reason: "provisioning_pending" })
    await runInDurableObject(stub, async (i, s) => {
      await quiesce(i, s)
      i.signupMachineReady = true
      // Clear only this test's retry delay; the durable items are retried by the real alarm drain.
      i.boundEngine.outbox.succeeded(`UserDO:${user}`)
    })
    await fireAlarm(stub)
    const chiefId = await runInDurableObject(stub, async (i, s) => {
      await quiesce(i, s)
      const state = i.boundEngine.currentState as UserState
      const chief = state.chiefs?.[state.hosted_default!]
      expect(chief).toMatchObject({ is_default: true, brain_place: null, cloud_machine: { workspace: defaultChiefWorkspace(user), team, connection_machine: carrier } })
      expect(chief?.cloud_machine?.install).toMatch(/^inst_[0-9a-f]{20}$/)
      expect(Object.values(state.chiefs ?? {})).toHaveLength(1)
      expect(i.boundEngine.outbox.allPending(100).filter((o: { kind: string }) => o.kind === DEFAULT_CHIEF_ENSURE || o.kind === DEFAULT_CHIEF_PROVISION)).toEqual([])
      return chief!.id
    })
    expect(chiefId).toBe(pendingId)
    expect(await brain.admit(chiefId, user, true)).toMatchObject({ ok: true, machine: { binding: { connection_machine: carrier } } })
    expect(await brain.configure(chiefId, user, { enabled: false })).toMatchObject({ ok: true })
    // The account's default can move while signup retains its selected hosted Chief.
    const other = await (stub as unknown as { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string }> }> }).submit(user, request, {
      t: "op", op: "chief.create", params: { display_name: "Research", is_default: true }, idempotency_key: "another-default", origin: "user"
    })
    expect(other.frames.some((f) => f.t === "result")).toBe(true)
    // A crash after activation can replay signup even after the owner deliberately turned it off.
    await (stub as unknown as { systemDeliver(e: string, source: string, items: Array<TargetItem>): Promise<unknown> }).systemDeliver(user, `user:${user}`, [
      { id: 100, op: DEFAULT_CHIEF_ENSURE, key: HOSTED_DEFAULT_KEY, params: {} }
    ])
    expect((await brain.status()).config.enabled).toBe(false)
    expect(await brain.admit(chiefId, user, true)).toEqual({ ok: false, reason: "disabled" })
  }, 60_000)
})
