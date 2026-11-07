import type { ChiefCloudMachine } from "./domains/user-chief.ts"
import { DEFAULT_CHIEF_ENSURE, DEFAULT_CHIEF_PROVISION, HOSTED_DEFAULT_KEY, defaultChiefVmInstall, defaultChiefWorkspace } from "./domains/user-chief-default.ts"
import { personalTeamIdFor, type UserState } from "./domains/user.ts"
import type { DeliverResult, TargetItem } from "./do-outbox.ts"
import type { SubmitResult } from "./owner-do.ts"

/** Trusted RPC on the existing platform service binding; no HTTP route or user credential reaches it. */
export interface DefaultMachinePlatform {
  ensureDefaultMachine(user: string): Promise<
    | { ok: true; value: { workspace: string; team: string; connectionMachine: string; machine: { id: string; provider: string; creator: string; visibility: string; kind: string } } }
    | { ok: false; code: string; message: string; retryable: boolean }
  >
}

export const provisioningFailure = (code: string, retryable = true): Error & { retryable: boolean } =>
  Object.assign(new Error(code), { retryable })

/** Admission stays in the platform's normal workspace ensure; never trust a cross-account response. */
export const ensureChiefMachine = async (platform: DefaultMachinePlatform | undefined, user: string, current: () => UserState, now: () => number = Date.now): Promise<ChiefCloudMachine> => {
  if (!platform) throw provisioningFailure("chief.provision.platform_unbound")
  let reply: Awaited<ReturnType<DefaultMachinePlatform["ensureDefaultMachine"]>>
  try { reply = await platform.ensureDefaultMachine(user) } catch { throw provisioningFailure("chief.provision.platform_unreachable") }
  if (!reply.ok) throw provisioningFailure(reply.code, reply.retryable)
  const v = reply.value, m = v?.machine
  if (!v || v.workspace !== defaultChiefWorkspace(user) || v.team !== personalTeamIdFor(user)
    || !m || m.creator !== user || m.visibility !== "private" || m.kind !== "user"
    || typeof m.id !== "string" || m.id.length === 0 || m.id.length > 256
    || typeof m.provider !== "string" || m.provider.length === 0 || m.provider.length > 256
    || typeof v.connectionMachine !== "string" || !/^vm_[a-z0-9]{20}$/.test(v.connectionMachine)) {
    throw provisioningFailure("chief.provision.invalid_machine", false)
  }
  const install = defaultChiefVmInstall(current(), v.team, v.connectionMachine, now())
  if (!install) throw provisioningFailure("chief.provision.machine_binding_pending")
  return { workspace: v.workspace, team: v.team, machine: m.id, provider: m.provider, connection_machine: v.connectionMachine, install }
}

interface SignupChiefHost {
  readonly platform: DefaultMachinePlatform | undefined
  current(): UserState | undefined
  deliver(items: ReadonlyArray<TargetItem>): Promise<DeliverResult>
  activate(agent: string, owner: string): Promise<{ ok: true } | { ok: false; reason: string }>
  bind(machine: ChiefCloudMachine, key: string): SubmitResult
}

/** Outbox retries own all network work; no user.ensure request waits on a VM boot. */
export const deliverSignupChief = async (entity: string, source: string, items: ReadonlyArray<TargetItem>, host: SignupChiefHost): Promise<DeliverResult> => {
  if (!items.some((i) => i.op === DEFAULT_CHIEF_ENSURE || i.op === DEFAULT_CHIEF_PROVISION)) return host.deliver(items)
  if (source !== `user:${entity}` || host.current()?.user?.id !== entity) throw provisioningFailure("chief.provision.wrong_owner", false)
  for (const item of items) if (item.op === DEFAULT_CHIEF_ENSURE || item.op === DEFAULT_CHIEF_PROVISION) {
    if (item.key !== (item.op === DEFAULT_CHIEF_ENSURE ? HOSTED_DEFAULT_KEY : `chief-default-machine:${entity}`)
      || !item.params || typeof item.params !== "object" || Array.isArray(item.params) || Object.keys(item.params).length !== 0) {
      throw provisioningFailure("chief.provision.invalid_item", false)
    }
  }
  // Deployed environments bind the platform; a local worker without it keeps signup pending.
  if (!host.platform) throw provisioningFailure("chief.provision.platform_unbound")
  const activate = async (agent: string) => {
    let activated: Awaited<ReturnType<SignupChiefHost["activate"]>>
    try { activated = await host.activate(agent, entity) } catch { throw provisioningFailure("chief.provision.brain_unreachable") }
    // The settings object writes its initial enable only once. A later user disable wins.
    if (!activated.ok && activated.reason !== "disabled") throw provisioningFailure(`chief.provision.${activated.reason}`, ["provisioning_pending", "owner.unreachable"].includes(activated.reason))
  }
  const done: Array<number> = []
  for (const item of items) {
    if (item.op !== DEFAULT_CHIEF_PROVISION) {
      const delivered = await host.deliver([item])
      if (item.op === DEFAULT_CHIEF_ENSURE && delivered.done.includes(item.id)) {
        const state = host.current()!
        const chief = state.hosted_default ? state.chiefs?.[state.hosted_default] : undefined
        if (chief && chief.archived_at === null && !chief.brain_place) await activate(chief.id)
      }
      done.push(...delivered.done)
      continue
    }
    const state = host.current()!
    const chief = state.hosted_default ? state.chiefs?.[state.hosted_default] : undefined
    // A person archived, deleted or moved their Chief while provisioning was outstanding.
    if (!chief || chief.archived_at !== null || chief.brain_place) { done.push(item.id); continue }
    if (chief.cloud_machine) { await activate(chief.id); done.push(item.id); continue }
    const machine = await ensureChiefMachine(host.platform, entity, () => host.current()!)
    const current = host.current()?.chiefs?.[chief.id]
    if (!current || current.archived_at !== null || current.brain_place) { done.push(item.id); continue }
    const reply = host.bind(machine, item.key).frames.find((f) => f.t === "reject" || f.t === "result")
    if (!reply) throw provisioningFailure("chief.provision.bind_unanswered")
    if (reply.t === "reject") throw provisioningFailure(reply.code, reply.retryable === true)
    await activate(chief.id)
    done.push(item.id)
  }
  return { done }
}
