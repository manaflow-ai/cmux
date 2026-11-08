import type { OutboxItem, Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import { HOSTED_DEFAULT_KEY, reduceChief, type ChiefCloudMachine, type ChiefRecord } from "./user-chief.ts"
import { personalTeamIdFor, type UserState } from "./user.ts"

/** Also used by the Mac's ensureHosted; the server selects it before any client is needed. */
export { HOSTED_DEFAULT_KEY } from "./user-chief.ts"
export const DEFAULT_CHIEF_ENSURE = "chief.default.ensure"
export const DEFAULT_CHIEF_PROVISION = "chief.default.provision"
export const DEFAULT_CHIEF_BIND = "chief.default.bind"
export const DEFAULT_CHIEF_OPS = new Set([DEFAULT_CHIEF_ENSURE, DEFAULT_CHIEF_BIND])
export const defaultChiefWorkspace = (user: string) => `chief-default-${user}`
export const defaultChiefIdentity = (user: string) => `system:user:${user}`
export const defaultChiefAllowed = (state: UserState, p: Principal) =>
  !!state.user && p.kind === "system" && p.identity === defaultChiefIdentity(state.user.id)

export const signupChiefOutbox = (user: string): ReadonlyArray<OutboxItem> => [
  { kind: DEFAULT_CHIEF_ENSURE, entity: HOSTED_DEFAULT_KEY, payload: {}, target: { class: "UserDO", name: user } },
  { kind: DEFAULT_CHIEF_PROVISION, entity: `chief-default-machine:${user}`, payload: {}, target: { class: "UserDO", name: user } }
]

const reject = (code: string, message: string): ReduceResult<UserState> => ({ ok: false, code, message })
const shortId = (v: unknown): v is string => typeof v === "string" && v.length > 0 && v.length <= 256

/** Registration is owned by the VM bind path; signup never makes or widens an install grant. */
export const defaultChiefVmInstall = (state: UserState, team: string, machine: string, now: number): string | undefined => {
  const matches = Object.values(state.installs).filter((i) => {
    const grant = state.grants[i.grant]
    return i.kind === "vm" && i.revoked_at === null && i.bound_team === team && i.bound_machine === machine
      && grant?.grantee === i.id && grant.revoked_at === null && grant.op_classes.includes("vm-self")
      && (grant.expires_at === null || grant.expires_at > now)
  })
  return matches.length === 1 ? matches[0]!.id : undefined
}

/** Only UserDO's own durable signup outbox can create or bind its one automatic Chief. */
export const reduceDefaultChief = (state: UserState, op: string, params: unknown, ctx: ReduceContext): ReduceResult<UserState> => {
  if (!defaultChiefAllowed(state, ctx.principal)) return reject("auth.forbidden", "only this user's signup outbox provisions its default Chief")
  const user = state.user!
  if (op === DEFAULT_CHIEF_ENSURE) {
    if (!params || typeof params !== "object" || Array.isArray(params) || Object.keys(params).length !== 0) return reject("validation.invalid", "default Chief ensure takes no params")
    // A user who later archives or deletes this Chief keeps that choice, even after ledger pruning.
    if (state.hosted_default) return { ok: true, state, value: state.chiefs?.[state.hosted_default] ?? null, changed: false }
    // A client can win the race with signup delivery. Adopt its hosted Chief rather than duplicating it.
    const hosted = Object.values(state.chiefs ?? {}).filter((c) => c.archived_at === null && !c.brain_place)
    const existing = hosted.find((c) => c.is_default) ?? hosted[0]
    if (existing) return { ok: true, state: { ...state, hosted_default: existing.id }, value: existing }
    const created = reduceChief(state, "chief.create", { display_name: "Chief", is_default: true }, {
      ...ctx,
      // The fixed key is the stable creation seed, independent of an outbox retry's transaction.
      tx: HOSTED_DEFAULT_KEY,
      principal: { identity: `signup:${user.id}`, kind: "session", user: user.id }
    })
    if (!created.ok) return created
    return { ...created, state: { ...created.state, hosted_default: (created.value as ChiefRecord).id } }
  }
  if (op !== DEFAULT_CHIEF_BIND) return reject("validation.invalid", "unknown default Chief op")
  const v = params as Partial<ChiefCloudMachine> | null
  if (!v || typeof v !== "object" || Object.keys(v).some((k) => !["workspace", "team", "machine", "provider", "connection_machine", "install"].includes(k))
    || v.workspace !== defaultChiefWorkspace(user.id) || v.team !== personalTeamIdFor(user.id) || !shortId(v.machine) || !shortId(v.provider)
    || typeof v.connection_machine !== "string" || !/^vm_[a-z0-9]{20}$/.test(v.connection_machine)
    || typeof v.install !== "string" || v.install !== defaultChiefVmInstall(state, v.team, v.connection_machine, ctx.now)) {
    return reject("validation.invalid", "default Chief machine must belong to this user's fixed workspace and personal team")
  }
  const chief = state.hosted_default ? state.chiefs?.[state.hosted_default] : undefined
  if (!chief || chief.archived_at !== null || chief.brain_place) return reject("chief.unavailable", "the signup Chief is no longer hosted")
  const binding: ChiefCloudMachine = { workspace: v.workspace, team: v.team, machine: v.machine, provider: v.provider, connection_machine: v.connection_machine, install: v.install }
  if (chief.cloud_machine) return JSON.stringify(chief.cloud_machine) === JSON.stringify(binding)
    ? { ok: true, state, value: chief, changed: false }
    : reject("auth.forbidden", "signup provisioning cannot replace the Chief's machine")
  const updated: ChiefRecord = { ...chief, cloud_machine: binding, rev: chief.rev + 1, updated_at: new Date(ctx.now).toISOString() }
  return { ok: true, state: { ...state, chiefs: { ...state.chiefs, [chief.id]: updated } }, value: updated }
}
