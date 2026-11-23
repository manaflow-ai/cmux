import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import type { Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { DEFAULT_CHIEF_BACKFILL, DEFAULT_CHIEF_BIND, DEFAULT_CHIEF_ENSURE, DEFAULT_CHIEF_REBIND, DEFAULT_CHIEF_PROVISION, HOSTED_DEFAULT_KEY, defaultChiefIdentity, defaultChiefWorkspace } from "../src/domains/user-chief-default.ts"
import { personalTeamIdFor, userDomain, type UserState } from "../src/domains/user.ts"
import { backfillDefaultChief, deliverSignupChief, ensureChiefMachine, rebindDefaultChief, type DefaultMachinePlatform } from "../src/user-chief-provision.ts"
import type { TargetItem } from "../src/do-outbox.ts"
import type { Env } from "../src/env.ts"
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

  it("a rebind follows the same logical machine to its new VM and install, and nothing else", () => {
    const VM2 = "vm_00000000000000000002", INSTALL2 = "inst_00000000000000000002"
    const bound = decided(userDomain.reduce(machineState(), DEFAULT_CHIEF_BIND, binding, context())).state
    expect(userDomain.reduce(machineState(), DEFAULT_CHIEF_REBIND, binding, context())).toMatchObject({ ok: false, code: "chief.unavailable" })
    // The platform registered the new VM's own install; the old one is revoked with the old VM.
    const moved: UserState = {
      ...bound,
      installs: { ...bound.installs, [INSTALL]: { ...bound.installs[INSTALL]!, revoked_at: 2 }, [INSTALL2]: { ...bound.installs[INSTALL]!, id: INSTALL2, grant: "grant_00000000000000000002", bound_machine: VM2 } },
      grants: { ...bound.grants, grant_00000000000000000002: { ...bound.grants.grant_00000000000000000001!, id: "grant_00000000000000000002", grantee: INSTALL2 } }
    }
    const next = { ...binding, connection_machine: VM2, install: INSTALL2 }
    const rebound = decided(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, next, context()))
    expect(rebound.state.chiefs?.[bound.hosted_default!]).toMatchObject({ brain_place: null, cloud_machine: next })
    expect(rebound.state.grants).toEqual(moved.grants)
    expect(decided(userDomain.reduce(rebound.state, DEFAULT_CHIEF_REBIND, next, context())).changed).toBe(false)
    // Signup's bind still never replaces a machine.
    expect(userDomain.reduce(moved, DEFAULT_CHIEF_BIND, next, context())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, { ...next, machine: "another-logical-machine" }, context())).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, { ...next, provider: "other-provider" }, context())).toMatchObject({ ok: false, code: "auth.forbidden" })
    // The new VM must hold its own live install; the old VM's revoked one never binds.
    expect(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, { ...next, install: INSTALL }, context())).toMatchObject({ ok: false, code: "validation.invalid" })
    expect(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, { ...binding, connection_machine: VM2 }, context())).toMatchObject({ ok: false, code: "validation.invalid" })
    for (const principal of [session, { identity: "system:user:someone-else", kind: "system" as const }]) {
      expect(userDomain.authorize?.(moved, DEFAULT_CHIEF_REBIND, next, principal)?.code).toBe("auth.forbidden")
      expect(userDomain.reduce(moved, DEFAULT_CHIEF_REBIND, next, context(principal))).toMatchObject({ ok: false, code: "auth.forbidden" })
    }
  })

  it("rebinds only when the platform names another VM for the same logical machine", async () => {
    const VM2 = "vm_00000000000000000002", INSTALL2 = "inst_00000000000000000002"
    let state = decided(userDomain.reduce(machineState(), DEFAULT_CHIEF_BIND, binding, context())).state
    const agent = state.hosted_default!
    const submit = (machine: typeof binding, key: string) => {
      const r = userDomain.reduce(state, DEFAULT_CHIEF_REBIND, machine, context())
      if (!r.ok) return { frames: [{ t: "reject" as const, tx: "rebind", idempotency_key: key, code: r.code, message: r.message, retryable: false, replayed: false }] }
      state = r.state
      return { frames: [{ t: "result" as const, tx: "rebind", idempotency_key: key, value: machine, revision: "2", replayed: false }] }
    }
    const now = () => context().now
    expect(await rebindDefaultChief(platform(), USER, agent, () => state, submit, now)).toEqual({ ok: true, changed: false, binding })
    expect(await rebindDefaultChief(platform(), USER, "agent_other", () => state, submit, now)).toMatchObject({ ok: false, code: "chief.machine.not_default", retryable: false })
    // The new VM has not registered its install yet: retry later, change nothing.
    expect(await rebindDefaultChief(platform({ ...platformValue(), connectionMachine: VM2 }), USER, agent, () => state, submit, now)).toMatchObject({ ok: false, code: "chief.provision.machine_binding_pending", retryable: true })
    expect(await rebindDefaultChief(platform({ ...platformValue(), machine: { ...platformValue().machine, id: "another-logical-machine" } }), USER, agent, () => state, submit, now)).toMatchObject({ ok: false, code: "chief.machine.binding_changed", retryable: false })
    state = {
      ...state,
      installs: { ...state.installs, [INSTALL2]: { ...state.installs[INSTALL]!, id: INSTALL2, grant: "grant_00000000000000000002", bound_machine: VM2 } },
      grants: { ...state.grants, grant_00000000000000000002: { ...state.grants.grant_00000000000000000001!, id: "grant_00000000000000000002", grantee: INSTALL2 } }
    }
    const next = { ...binding, connection_machine: VM2, install: INSTALL2 }
    expect(await rebindDefaultChief(platform({ ...platformValue(), connectionMachine: VM2 }), USER, agent, () => state, submit, now)).toEqual({ ok: true, changed: true, binding: next })
    expect(state.chiefs?.[agent]?.cloud_machine).toEqual(next)
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

describe("default Chief backfill for accounts older than signup provisioning", () => {
  const ON = { CHIEF_BRAIN_ENABLED: "1", HANDS_ENABLED: "1" } as unknown as Env
  const signupOutbox = [
    { kind: DEFAULT_CHIEF_ENSURE, entity: HOSTED_DEFAULT_KEY, payload: {}, target: { class: "UserDO", name: USER } },
    { kind: DEFAULT_CHIEF_PROVISION, entity: `chief-default-machine:${USER}`, payload: {}, target: { class: "UserDO", name: USER } }
  ]
  // An account whose first ensure predates #33131: a profile, a Mac-made hosted Chief, no machine.
  const oldAccount = (): UserState => decided(userDomain.reduce(existing(), "chief.create", { display_name: "Chief", is_default: true }, { ...context(session), idempotencyKey: HOSTED_DEFAULT_KEY })).state
  const host = (start: UserState) => {
    let state = start
    const outbox: Array<unknown> = []
    const keys: Array<string> = []
    const submit = (op: string, key: string) => {
      keys.push(key)
      const principal: Principal = { identity: defaultChiefIdentity(USER), kind: "system" }
      const refused = userDomain.authorize?.(state, op, {}, principal)
      const r = refused ? { ok: false as const, ...refused } : userDomain.reduce(state, op, {}, context(principal, key))
      if (!r.ok) return { frames: [{ t: "reject" as const, tx: key, idempotency_key: key, code: r.code, message: r.message, retryable: false, replayed: false }] }
      state = r.state
      outbox.push(...(r.outbox ?? []))
      return { frames: [{ t: "result" as const, tx: key, idempotency_key: key, value: r.value, revision: "1", replayed: false }] }
    }
    return { submit, outbox, keys, state: () => state }
  }

  it("an old account queues the signup outbox exactly once, and the outbox gives its Chief the machine", async () => {
    const h = host(oldAccount())
    expect(backfillDefaultChief(ON, h.state(), h.submit)).toBe("queued")
    expect(h.outbox).toEqual(signupOutbox)
    // The selection is made at enqueue, before the owner can change anything.
    expect(h.state().hosted_default).toBe(Object.keys(h.state().chiefs ?? {})[0])
    expect(h.keys).toEqual([`chief-default-backfill:${USER}`])
    // Later ensures, and a second ensure racing the first, find the account marked and queue nothing.
    expect(backfillDefaultChief(ON, h.state(), h.submit)).toBe("not_due")
    const raced = decided(userDomain.reduce(h.state(), DEFAULT_CHIEF_BACKFILL, {}, context(undefined, "raced")))
    expect(raced.changed).toBe(false)
    expect(raced.outbox).toBeUndefined()
    expect(h.outbox).toHaveLength(2)
    // The queued outbox adopts the Mac's Chief (no second Chief) and binds its machine.
    let state = h.state()
    const chief = Object.keys(state.chiefs ?? {})
    const items = signupOutbox.map((o, i) => ({ id: i + 1, op: o.kind, key: o.entity, params: {} }))
    const delivered = await deliverSignupChief(USER, `user:${USER}`, items, {
      platform: platform(),
      current: () => state,
      activate: async () => ({ ok: true as const }),
      deliver: async (batch: ReadonlyArray<TargetItem>) => {
        for (const item of batch) state = machineState(decided(userDomain.reduce(state, item.op, item.params, context())).state)
        return { done: batch.map((item) => item.id) }
      },
      bind: (machine: typeof binding) => {
        state = decided(userDomain.reduce(state, DEFAULT_CHIEF_BIND, machine, context())).state
        return { frames: [{ t: "result" as const, tx: "bind", idempotency_key: "bind", value: machine, revision: "1", replayed: false }] }
      }
    })
    expect(delivered).toEqual({ done: [1, 2] })
    expect(Object.keys(state.chiefs ?? {})).toEqual(chief)
    expect(state.hosted_default).toBe(chief[0])
    expect(state.chiefs?.[chief[0]!]?.cloud_machine).toEqual(binding)
  })

  it("an account that already has its machine, or chose otherwise, is untouched", () => {
    const bound = decided(userDomain.reduce(machineState(), DEFAULT_CHIEF_BIND, binding, context())).state
    const selected = ensured(), id = selected.hosted_default!, chief = selected.chiefs![id]!
    const archived: UserState = { ...selected, chiefs: { [id]: { ...chief, archived_at: new Date(1).toISOString() } } }
    const deleted: UserState = { ...selected, chiefs: {} }
    const placed: UserState = { ...selected, chiefs: { [id]: { ...chief, brain_place: { host: "host_00000000000000000001", install: "inst_00000000000000000009" } as never } } }
    for (const state of [bound, archived, deleted, placed, { ...oldAccount(), migrations: { default_chief_machine: true as const } }]) {
      const h = host(state)
      expect(backfillDefaultChief(ON, state, h.submit)).toBe("not_due")
      expect(h.keys).toEqual([])
      const direct = decided(userDomain.reduce(state, DEFAULT_CHIEF_BACKFILL, {}, context()))
      expect(direct.changed).toBe(false)
      expect(direct.state).toBe(state)
    }
    // A new account's first ensure queues signup provisioning and marks it, so the backfill never doubles it.
    const signup = decided(userDomain.reduce(userDomain.initial(), "user.ensure", {}, context(session))).state
    expect(signup.migrations?.default_chief_machine).toBe(true)
    expect(backfillDefaultChief(ON, signup, host(signup).submit)).toBe("not_due")
  })

  it("an account older than signup (no hosted_default) is due only for its hosted, unplaced default Chief or no Chief ever", () => {
    const legacy = oldAccount()
    expect(legacy.hosted_default).toBeUndefined()
    const id = Object.keys(legacy.chiefs ?? {})[0]!, hosted = legacy.chiefs![id]!
    const PLACE = { host: "host_00000000000000000001", install: "inst_00000000000000000009" } as never
    const placedChief = { ...hosted, id: "agent_00000000000000000009", display_name: "Chief (Mac mini)", brain_place: PLACE }
    const at = new Date(1).toISOString()
    const due = (state: UserState) => {
      const h = host(state)
      const outcome = backfillDefaultChief(ON, state, h.submit)
      const direct = decided(userDomain.reduce(state, DEFAULT_CHIEF_BACKFILL, {}, context()))
      expect(direct.changed !== false).toBe(outcome === "queued")
      if (outcome !== "queued") expect(direct.state).toBe(state)
      return outcome
    }
    // The Mac's ensureHosted Chief, and an account that never had a Chief, are due (as at signup).
    expect(due(legacy)).toBe("queued")
    expect(due(existing())).toBe("queued")
    // The default Chief is placed on a server (the Mac mini), alone or beside a hosted non-default one.
    expect(due({ ...legacy, chiefs: { [id]: { ...hosted, brain_place: PLACE } } })).toBe("not_due")
    expect(due({ ...legacy, chiefs: { [id]: { ...hosted, is_default: false }, [placedChief.id]: placedChief } })).toBe("not_due")
    // The person archived or deleted their Chiefs and none is left.
    expect(due({ ...legacy, chiefs: { [id]: { ...hosted, is_default: false, archived_at: at } } })).toBe("not_due")
    expect(due({ ...legacy, chiefs: {}, chief_tombstones: { [id]: { id, owner_user: USER, archived_at: at } } })).toBe("not_due")
    // A live Chief that is not the default, with the hosted one archived: no plain default to adopt.
    expect(due({ ...legacy, chiefs: { [id]: { ...hosted, is_default: false, archived_at: at }, other: { ...hosted, id: "other", is_default: false } } })).toBe("not_due")
  })

  it("enqueue, then an owner change, then delivery: the owner's choice stands and no hosted default is made", async () => {
    const PLACE = { host: "host_00000000000000000001", install: "inst_00000000000000000009" } as never
    const at = new Date(2).toISOString()
    const deliver = async (start: UserState) => {
      let state = start
      const activated: Array<string> = []
      const items = signupOutbox.map((o, i) => ({ id: i + 1, op: o.kind, key: o.entity, params: {} }))
      const done = await deliverSignupChief(USER, `user:${USER}`, items, {
        platform: platform(),
        current: () => state,
        activate: async (agent: string) => { activated.push(agent); return { ok: true as const } },
        deliver: async (batch: ReadonlyArray<TargetItem>) => {
          for (const item of batch) state = machineState(decided(userDomain.reduce(state, item.op, item.params, context(undefined, `deliver-${item.id}`))).state)
          return { done: batch.map((item) => item.id) }
        },
        bind: (machine: typeof binding) => {
          state = decided(userDomain.reduce(state, DEFAULT_CHIEF_BIND, machine, context())).state
          return { frames: [{ t: "result" as const, tx: "bind", idempotency_key: "bind", value: machine, revision: "1", replayed: false }] }
        }
      })
      return { state, activated, done }
    }
    for (const start of [oldAccount(), existing()]) {
      const h = host(start)
      expect(backfillDefaultChief(ON, h.state(), h.submit)).toBe("queued")
      const queued = h.state(), id = queued.hosted_default!, hosted = queued.chiefs![id]!
      const placed = { ...hosted, id: "agent_00000000000000000009", display_name: "Chief (Mac mini)", brain_place: PLACE }
      const changes: Record<string, UserState> = {
        // The owner made a placed Chief the default, then archived or deleted the hosted one.
        archived: { ...queued, chiefs: { [id]: { ...hosted, is_default: false, archived_at: at }, [placed.id]: placed } },
        deleted: { ...queued, chiefs: { [placed.id]: placed }, chief_tombstones: { [id]: { id, owner_user: USER, archived_at: at } } },
        // The owner placed the hosted Chief itself on a server.
        placed: { ...queued, chiefs: { [id]: { ...hosted, brain_place: PLACE } } }
      }
      for (const [kind, changed] of Object.entries(changes)) {
        const r = await deliver(changed)
        expect(r.done, kind).toEqual({ done: [1, 2] })
        expect(r.state.chiefs, kind).toEqual(changed.chiefs)
        expect(r.state.hosted_default, kind).toBe(id)
        expect(r.activated, kind).toEqual([])
      }
      // The owner made the placed Chief the default and kept the hosted one: the default stays theirs.
      const switched: UserState = { ...queued, chiefs: { [id]: { ...hosted, is_default: false }, [placed.id]: { ...placed, is_default: true } } }
      const r = await deliver(switched)
      expect(Object.keys(r.state.chiefs ?? {}).sort()).toEqual([id, placed.id].sort())
      expect(r.state.chiefs?.[placed.id]).toEqual(switched.chiefs![placed.id])
      expect(r.state.chiefs?.[id]?.is_default).toBe(false)
    }
  })

  it("a Chief on a harness the machine does not run stays hosted; Claude and Codex Chiefs are due", () => {
    const legacy = oldAccount(), id = Object.keys(legacy.chiefs ?? {})[0]!, chief = legacy.chiefs![id]!
    const withHarness = (state: UserState, harness: string | null): UserState => ({ ...state, chiefs: { ...state.chiefs, [state.hosted_default ?? id]: { ...state.chiefs![state.hosted_default ?? id]!, harness } } })
    for (const start of [legacy, ensured()]) {
      for (const harness of ["opencode", "claude-sr", "pi", "gemini"]) {
        const state = withHarness(start, harness)
        const h = host(state)
        expect(backfillDefaultChief(ON, state, h.submit), harness).toBe("not_due")
        expect(h.keys).toEqual([])
        expect(decided(userDomain.reduce(state, DEFAULT_CHIEF_BACKFILL, {}, context())).state).toBe(state)
      }
      for (const harness of [null, "claude", "codex"]) expect(backfillDefaultChief(ON, withHarness(start, harness), host(withHarness(start, harness)).submit), String(harness)).toBe("queued")
    }
    expect(chief.harness).toBeNull()
  })

  it("an owner on the Claude Code route keeps it: no machine would take its turns over", () => {
    const cc = { ...ON, ENVIRONMENT: "staging", CHIEF_CC_ENABLED: "1", CHIEF_CC_FREESTYLE_API_KEY: "k", CHIEF_CC_TS_OAUTH: "o", CHIEF_CC_SNAPSHOT: "s", CHIEF_CC_OWNERS: TEAM, CHIEF_BRAIN_CLAUDE_OWNERS: USER } as unknown as Env
    const h = host(oldAccount())
    expect(backfillDefaultChief(cc, h.state(), h.submit)).toBe("not_due")
    expect(h.keys).toEqual([])
    // Named on the list but not a paid-model owner: not on the route, so due.
    expect(backfillDefaultChief({ ...cc, CHIEF_BRAIN_CLAUDE_OWNERS: "" } as unknown as Env, h.state(), h.submit)).toBe("queued")
  })

  it("is off unless both CHIEF_BRAIN_ENABLED and HANDS_ENABLED are 1, as production is today", () => {
    for (const env of [{}, { CHIEF_BRAIN_ENABLED: "1" }, { HANDS_ENABLED: "1" }, { CHIEF_BRAIN_ENABLED: "1", HANDS_ENABLED: "0" }]) {
      const h = host(oldAccount())
      expect(backfillDefaultChief(env as unknown as Env, h.state(), h.submit)).toBe("off")
      expect(h.keys).toEqual([])
    }
  })

  it("only the account's own system identity can queue it", () => {
    for (const principal of [session, { identity: "system:user:someone-else", kind: "system" as const }, { identity: "system:cloud", kind: "system" as const }]) {
      expect(userDomain.authorize?.(oldAccount(), DEFAULT_CHIEF_BACKFILL, {}, principal)?.code).toBe("auth.forbidden")
      expect(userDomain.reduce(oldAccount(), DEFAULT_CHIEF_BACKFILL, {}, context(principal))).toMatchObject({ ok: false, code: "auth.forbidden" })
    }
    expect(userDomain.reduce(oldAccount(), DEFAULT_CHIEF_BACKFILL, { machine: "foreign" }, context())).toMatchObject({ ok: false, code: "validation.invalid" })
  })

  it("a failure to queue never fails the ensure, and a provisioning outage stays in the outbox to retry", async () => {
    const state = oldAccount()
    expect(backfillDefaultChief(ON, state, () => { throw new Error("storage") })).toBe("failed")
    expect(backfillDefaultChief(ON, state, (_op, key) => ({ frames: [{ t: "reject" as const, tx: key, idempotency_key: key, code: "x", message: "x", retryable: true, replayed: false }] }))).toBe("failed")
    // The platform is down: delivery throws a retryable error for the outbox, and the user's state is unchanged.
    const h = host(state)
    expect(backfillDefaultChief(ON, h.state(), h.submit)).toBe("queued")
    let current = h.state()
    const items = [{ id: 1, op: DEFAULT_CHIEF_ENSURE, key: HOSTED_DEFAULT_KEY, params: {} }, { id: 2, op: DEFAULT_CHIEF_PROVISION, key: `chief-default-machine:${USER}`, params: {} }]
    await expect(deliverSignupChief(USER, `user:${USER}`, items, {
      platform: { ensureDefaultMachine: async () => { throw new Error("down") } },
      current: () => current,
      activate: async () => ({ ok: true as const }),
      deliver: async (batch: ReadonlyArray<TargetItem>) => {
        for (const item of batch) current = decided(userDomain.reduce(current, item.op, item.params, context())).state
        return { done: batch.map((item) => item.id) }
      },
      bind: () => { throw new Error("unreachable") }
    })).rejects.toMatchObject({ message: "chief.provision.platform_unreachable", retryable: true })
    expect(current.user).toEqual(profile)
  })
})

const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

// The signup outbox's end to end machine provisioning reaches CloudDO, which is cmux-platform's.
