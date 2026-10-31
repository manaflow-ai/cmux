import { personalTeamIdFor, userIdFor } from "./domains/user.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"
import { PersonalTenantStore, samePersonalMarker, validTenantId, type PersonalTenantIntent, type PersonalTenantMarker } from "./team-vm-api-personal-store.ts"
import { PersonalTenantIdentityError, type PersonalTenantReceipt, type PersonalTenantStack } from "./team-vm-api-personal-stack.ts"

export type EnsurePersonalTenantReply = { readonly status: "ready"; readonly target: VmApiTenant } | { readonly status: "pending" | "unavailable" }
export interface PersonalTenantDeps {
  readonly store: PersonalTenantStore
  readonly team: string
  readonly project: string
  /** Reads the current personal owner, not a caller-supplied user id. */
  readonly owner: () => string | null
  readonly stackUserOf: (user: string) => Promise<string | null>
  readonly stack: PersonalTenantStack | undefined
  readonly now: number
  readonly allowCreate: boolean
}

export const personalTenantTarget = (intent: PersonalTenantIntent | null, team: string, project: string): VmApiTenant | null =>
  intent?.phase === "ready" && intent.marker.team === team && intent.marker.project === project && validTenantId(intent.tenant)
    ? { team, tenant: intent.tenant, project } : null

/** One owner command. A committed creating phase means the POST may have happened, even after a restart. */
export const ensurePersonalTenant = async (deps: PersonalTenantDeps): Promise<EnsurePersonalTenantReply> => {
  const { store, team, project, now, stack } = deps
  const owner = deps.owner()
  if (!owner || personalTeamIdFor(owner) !== team || !project || project.length > 128 || project.trim() !== project || /[\r\n]/.test(project)) return { status: "unavailable" }
  const stackUser = await deps.stackUserOf(owner).catch(() => null)
  if (!stackUser || userIdFor(project, stackUser) !== owner || deps.owner() !== owner) return { status: "unavailable" }
  let intent: PersonalTenantIntent | null
  try { intent = store.read() } catch { return { status: "unavailable" } }
  if (intent && (intent.marker.project !== project || intent.marker.team !== team || intent.marker.user !== owner || intent.marker.stack_user !== stackUser)) return { status: "unavailable" }
  const target = personalTenantTarget(intent, team, project)
  if (target) return { status: "ready", target }
  if (!stack || (!intent && !deps.allowCreate)) return { status: "unavailable" }
  if (!intent) {
    const marker: PersonalTenantMarker = { version: 1, project, team, user: owner, stack_user: stackUser, nonce: crypto.randomUUID() }
    intent = store.reserve(marker, now)
  }
  const current = intent
  const finish = async (receipt: PersonalTenantReceipt): Promise<EnsurePersonalTenantReply> => {
    if (!validTenantId(receipt.id) || !samePersonalMarker(receipt.marker, current.marker)) return { status: "unavailable" }
    const members = await stack.members(receipt.id)
    if (members.length !== 1 || members[0] !== stackUser || deps.owner() !== owner) return { status: "unavailable" }
    store.ready(current, receipt.id)
    return { status: "ready", target: { team, tenant: receipt.id, project } }
  }
  try {
    const found = await stack.find(current.marker)
    if (found.length > 1) { store.retry(current, now); return { status: "unavailable" } }
    if (found[0]) {
      const reply = await finish(found[0])
      if (reply.status !== "ready") store.retry(current, now)
      return reply
    }
    if (current.phase === "creating") {
      store.retry(current, now)
      return { status: "pending" }
    }
    if (current.nextAt !== null && current.nextAt > now) return { status: "pending" }
    if (!deps.allowCreate) { store.parkPrepared(); return { status: "pending" } }
    if (deps.owner() !== owner) return { status: "unavailable" }
    const sent = store.sent(current, now)
    let receipt: PersonalTenantReceipt
    try { receipt = await stack.create(sent.marker) }
    catch (e) {
      store.retry(sent, now, e instanceof PersonalTenantIdentityError && e.definitelyUnsent)
      return { status: "pending" }
    }
    const reply = await finish(receipt)
    if (reply.status !== "ready") store.retry(sent, now)
    return reply
  } catch {
    // If the POST was sent, use the persisted phase: a later membership/read failure cannot make it safe to resend.
    const latest = store.read()
    if (latest && latest.phase !== "ready") store.retry(latest, now)
    return { status: "pending" }
  }
}
