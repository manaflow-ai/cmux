import { personalTeamIdFor, userIdFor } from "./domains/user.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"
import { PERSONAL_TENANT_CREATE_WINDOW_MS, PersonalTenantStore, samePersonalMarker, validTenantId, type PersonalTenantIntent, type PersonalTenantMarker } from "./team-vm-api-personal-store.ts"
import { PersonalTenantIdentityError, type PersonalTenantReceipt, type PersonalTenantStack, type PersonalTenantStackFailure } from "./team-vm-api-personal-stack.ts"

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

/** Why an ensure did not answer ready, for its one log line. */
interface NotReady { reason: string; failure?: PersonalTenantStackFailure }

/**
 * One owner command. A committed creating phase means the POST may have happened, even after a restart.
 * An answer other than ready logs one line: why, the ledger's phase, attempts and wake time, and the failed Stack
 * call's status and known-error code. Never the server key or a Stack answer body.
 */
export const ensurePersonalTenant = async (deps: PersonalTenantDeps): Promise<EnsurePersonalTenantReply> => {
  const why: NotReady = { reason: "unknown" }
  const reply = await ensureOnce(deps, why)
  if (reply.status !== "ready") {
    let ledger: PersonalTenantIntent | null | "unreadable"
    try { ledger = deps.store.read() } catch { ledger = "unreadable" }
    console.warn(JSON.stringify({
      msg: "personal vm api tenant not ready", team: deps.team, status: reply.status, reason: why.reason, ...(why.failure ? { stack: why.failure } : {}),
      create: deps.allowCreate, now: deps.now,
      ledger: ledger === "unreadable" || ledger === null ? ledger ?? "none" : { phase: ledger.phase, attempts: ledger.attempts, createdAt: ledger.createdAt, nextAt: ledger.nextAt }
    }))
  }
  return reply
}

const ensureOnce = async (deps: PersonalTenantDeps, why: NotReady): Promise<EnsurePersonalTenantReply> => {
  const { store, team, project, now, stack } = deps
  const no = (status: "pending" | "unavailable", reason: string, error?: unknown): EnsurePersonalTenantReply => {
    why.reason = reason
    if (error instanceof PersonalTenantIdentityError && error.failure) why.failure = error.failure
    else if (error !== undefined && !(error instanceof PersonalTenantIdentityError)) why.reason = `${reason}: ${error instanceof Error ? `${error.name}: ${error.message.slice(0, 160)}` : typeof error}`
    return { status }
  }
  const owner = deps.owner()
  if (!owner || personalTeamIdFor(owner) !== team || !project || project.length > 128 || project.trim() !== project || /[\r\n]/.test(project)) return no("unavailable", "no personal owner")
  const stackUser = await deps.stackUserOf(owner).catch(() => null)
  if (!stackUser || userIdFor(project, stackUser) !== owner || deps.owner() !== owner) return no("unavailable", "owner's Stack user missing or mismatched")
  let intent: PersonalTenantIntent | null
  try { intent = store.read() } catch { return no("unavailable", "ledger unreadable") }
  if (intent && (intent.marker.project !== project || intent.marker.team !== team || intent.marker.user !== owner || intent.marker.stack_user !== stackUser)) return no("unavailable", "ledger names another owner or project")
  const target = personalTenantTarget(intent, team, project)
  if (target) return { status: "ready", target }
  if (!stack) return no("unavailable", "no Stack server key")
  if (!intent && !deps.allowCreate) return no("unavailable", "no intent and not asked to create")
  if (!intent) {
    const marker: PersonalTenantMarker = { version: 1, project, team, user: owner, stack_user: stackUser, nonce: crypto.randomUUID() }
    intent = store.reserve(marker, now)
  }
  const current = intent
  const finish = async (receipt: PersonalTenantReceipt): Promise<EnsurePersonalTenantReply> => {
    if (!validTenantId(receipt.id) || !samePersonalMarker(receipt.marker, current.marker)) return no("unavailable", "Stack team's marker does not match")
    const members = await stack.members(receipt.id)
    if (members.length !== 1 || members[0] !== stackUser) return no("unavailable", `Stack team has ${members.length} members, not only the owner`)
    if (deps.owner() !== owner) return no("unavailable", "owner changed")
    store.ready(current, receipt.id)
    return { status: "ready", target: { team, tenant: receipt.id, project } }
  }
  try {
    const found = await stack.find(current.marker)
    if (found.length > 1) { store.retry(current, now); return no("unavailable", `${found.length} Stack teams carry this marker`) }
    if (found[0]) {
      const reply = await finish(found[0])
      if (reply.status !== "ready") store.retry(current, now)
      return reply
    }
    if (current.phase === "creating") {
      // Not found after the whole create window: an explicit create starts over under a fresh nonce.
      if (!deps.allowCreate || now < current.createdAt + PERSONAL_TENANT_CREATE_WINDOW_MS) {
        store.retry(current, now)
        return no("pending", deps.allowCreate ? "sent create not found yet, inside its create window" : "sent create not found yet (wake)")
      }
      current = store.renew(current, { ...current.marker, nonce: crypto.randomUUID() }, now)
    }
    if (current.nextAt !== null && current.nextAt > now) return no("pending", "backing off after a failed create")
    if (!deps.allowCreate) { store.parkPrepared(); return no("pending", "prepared, waiting for an explicit create") }
    if (deps.owner() !== owner) return no("unavailable", "owner changed")
    const sent = store.sent(current, now)
    let receipt: PersonalTenantReceipt
    try { receipt = await stack.create(sent.marker) }
    catch (e) {
      store.retry(sent, now, e instanceof PersonalTenantIdentityError && e.definitelyUnsent)
      return no("pending", "Stack create failed", e)
    }
    const reply = await finish(receipt)
    if (reply.status !== "ready") store.retry(sent, now)
    return reply
  } catch (e) {
    // If the POST was sent, use the persisted phase: a later membership/read failure cannot make it safe to resend.
    const latest = store.read()
    if (latest && latest.phase !== "ready") store.retry(latest, now)
    return no("pending", "Stack call failed", e)
  }
}
