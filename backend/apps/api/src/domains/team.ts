import type { Domain } from "@cmux/ownership"
import { HostEnroll, HostRemove, type Host, type TeamMember } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"
import { hostByInstall, hostDelete, hostOf, hostUpsert, memberLeftItems, memberOf, memberUpsert, roleOf, TABLE_HOST, TABLE_MEMBER, teamIndexItem, type LegacyTeamMaps } from "./team-members.ts"
import { appendAudit, type AuditState } from "./team-audit.ts"
import { reduceDomainClaim, reduceDomainLost, reduceDomainRechecked, reduceDomainReleased, reduceDomainVerified, type DomainState } from "./team-domains.ts"
import { reduceActivated, reduceConnectionCreate, reduceConnectionDisable, reduceSecretSet, type SsoState } from "./team-sso.ts"
import { reduceDeviceEnroll, reduceDeviceRelease, reduceReportStatus, reduceTokenCreate, reduceTokenRevoke, type EnrollmentState } from "./team-enrollment.ts"
import { reduceIntegrationLock, reduceIntegrationSeed, reduceIntegrationSynced, reduceReleaseDone, reduceReleaseLock, type IntegrationSyncState } from "./team-integration-sync.ts"
import { reducePolicyRollback, reducePolicyUpdate } from "./team-policy.ts"
import { reduceRunsSynced, type RunSyncState } from "./team-run-sync.ts"
import { reduceAccountAllocated, reduceCaInstalled, reduceCertsRevoked, type TeamSshState } from "./team-ssh.ts"
import { reduceServerEnrolled, reduceServerInstallRevoked, reduceServerRevoke, type ServerRevocation } from "./team-servers.ts"

export interface TeamState extends EnrollmentState, AuditState, IntegrationSyncState, RunSyncState, DomainState, SsoState, TeamSshState, LegacyTeamMaps {
  readonly team: { readonly id: string; readonly kind: "personal" | "stack"; readonly display_name: string } | null
  /** Members and hosts are rows (team-members.ts); the head keeps their counts. */
  readonly member_count?: number
  readonly host_count?: number
  /** Installs of removed servers whose UserDO revocation is not confirmed yet (TeamDO retries; server.md 6.5). */
  readonly server_revocations?: Readonly<Record<string, ServerRevocation>>
}

/**
 * TeamDO's reducer: the account directory (U2). Phase 1 knows personal teams
 * only; Stack teams arrive by webhook ops once the Stack webhook is configured.
 * Grants for team ops are checked by UserDO when it mints the token; TeamDO
 * checks membership and the op's principal kind.
 */
const HTTP_ONLY_OPS: ReadonlySet<string> = new Set([
  "sso.connection.set_secret",
  "sso.connection.activate",
  "domain.verify",
  "domain.release",
  // The SSH CA signs and seals outside the reducer (team-ssh-ca.ts).
  "team_vm.ssh_cert.challenge",
  "team_vm.ssh_cert",
  "team_vm.ssh_cert.revoke",
  "team_vm.ssh_ca.rotate"
])

export const teamDomain: Domain<TeamState> = {
  initial: () => ({ team: null, member_count: 0, host_count: 0 }),

  authorize: (state, op, _params, principal, rows) => {
    // HTTP-only ops (external effects; a secret in params): refused before the ledger, which would
    // otherwise keep an unsalted hash of the params (review P2). They run through the Worker's route.
    if (HTTP_ONLY_OPS.has(op)) return { code: "validation.invalid", message: `${op} runs through POST /v1/ops only` }
    // TeamDO's own ops (alarm work); admit allows a system principal only for internal ops.
    if (principal.kind === "system") return admit("cloud:TeamDO", op, principal, () => undefined, Date.now())
    if (op !== "team.ensure_personal") {
      if (!memberOf(state, rows, principal.user)) return { code: "auth.forbidden", message: "not a member of this team" }
    }
    // The grant lives in UserDO. The Worker asks UserDO on every install call
    // (revocation and grant) and passes the grant's classes; none means refuse.
    return admit("cloud:TeamDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "team.rows_migrate": {
        // (f) An old head's members and hosts move to rows in one commit; the maps leave the head.
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        if (state.members === undefined && state.hosts === undefined) return { ok: true, state, value: null, changed: false }
        const members = Object.values(state.members ?? {})
        const hosts = Object.values(state.hosts ?? {})
        const { members: _m, hosts: _h, ...rest } = state
        // Counts add only the map entries that have no row yet (a head may hold both after a rollback).
        const newMembers = members.filter((m) => !ctx.rows?.get(TABLE_MEMBER, m.user)).length
        const newHosts = hosts.filter((h) => !ctx.rows?.get(TABLE_HOST, h.id)).length
        return {
          ok: true,
          state: { ...rest, member_count: (state.member_count ?? 0) + newMembers, host_count: (state.host_count ?? 0) + newHosts },
          writes: [...members.map(memberUpsert), ...hosts.flatMap(hostUpsert)],
          ...(state.team ? { outbox: members.map((m) => teamIndexItem(state.team!, m.user, m.role, ctx.tx)) } : {}),
          value: { members: members.length, hosts: hosts.length }
        }
      }
      case "team.member.remove": {
        // Internal (cx-44j.47): the future members op and operator tools remove through here.
        // Only this TeamDO's own submitSystem (identity system:team), never a delivered outbox item.
        if (p.kind !== "system" || p.identity !== "system:team") return reject("auth.forbidden", "internal op")
        const user = (params as { user?: unknown } | null)?.user
        if (typeof user !== "string" || !user) return reject("validation.invalid", "user required")
        const member = memberOf(state, ctx.rows, user)
        if (!member) return { ok: true, state, value: { user, removed: false }, changed: false }
        // An owner is demoted first, so no team is ever left without one (a personal team's owner never leaves).
        if (member.role === "owner") return reject("auth.forbidden", "an owner cannot be removed; demote them first")
        const { [user]: _gone, ...legacyMembers } = state.members ?? {}
        return {
          ok: true,
          state: { ...state, ...(state.members?.[user] ? { members: legacyMembers } : {}), member_count: Math.max(0, (state.member_count ?? 0) - 1) },
          writes: [{ table: TABLE_MEMBER, op: "delete", key: user }],
          value: { user, removed: true },
          ...(state.team ? { outbox: memberLeftItems(state.team, user, ctx.tx, ctx.now) } : {})
        }
      }
      case "team.ensure_personal": {
        if (!p.user || !p.team) return reject("auth.forbidden", "needs a user session")
        if (state.team && state.team.id !== p.team) return reject("auth.forbidden", "not this team")
        const name = p.display_name ?? "Personal"
        const member: typeof TeamMember.Type = { user: p.user, role: "owner", display_name: name }
        const team = { id: p.team, kind: "personal" as const, display_name: name }
        const prior = memberOf(state, ctx.rows, p.user)
        const same = JSON.stringify(state.team) === JSON.stringify(team) && JSON.stringify(prior) === JSON.stringify(member)
        if (same) return { ok: true, state, value: team, changed: false }
        return {
          ok: true,
          state: { ...state, team, member_count: (state.member_count ?? 0) + (prior ? 0 : 1) },
          writes: [memberUpsert(member)],
          value: team,
          outbox: [
            { kind: "team.upsert", entity: team.id, payload: team },
            { kind: "membership.upsert", entity: `${team.id}:${p.user}`, payload: { team: team.id, ...member } },
            teamIndexItem(team, p.user, member.role, ctx.tx)
          ]
        }
      }
      case "host.enroll": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        const d = decodeParams<typeof HostEnroll.params.Type>(HostEnroll, params)
        if (!d.ok) return d
        if (!p.install || !p.user) return reject("auth.forbidden", "host.enroll needs an install token")
        const existing = hostByInstall(state, ctx.rows, p.install)
        const id = existing?.id ?? ctx.newId("host")
        const host: typeof Host.Type = { id, name: d.value.name, platform: d.value.platform, owner_user: p.user, enrolled_by: p.install, enrolled_at: existing?.enrolled_at ?? ctx.now }
        if (existing && JSON.stringify(existing) === JSON.stringify(host)) return { ok: true, state, value: host, changed: false }
        return {
          ok: true,
          state: { ...state, host_count: (state.host_count ?? 0) + (existing ? 0 : 1) },
          writes: hostUpsert(host),
          value: host,
          outbox: [{ kind: "host.upsert", entity: id, payload: { ...host, team: state.team.id } }]
        }
      }
      case "host.remove": {
        const d = decodeParams<typeof HostRemove.params.Type>(HostRemove, params)
        if (!d.ok) return d
        const host = hostOf(state, ctx.rows, d.value.host)
        if (!host) return reject("selector.not_found", "host not found")
        const role = roleOf(state, ctx.rows, p.user)
        if (host.owner_user !== p.user && role !== "owner" && role !== "admin") return reject("auth.forbidden", "only the host owner or a team admin may remove it")
        return {
          ok: true,
          state: { ...withoutLegacyHost(state, host.id), host_count: Math.max(0, (state.host_count ?? 1) - 1) },
          writes: hostDelete(host),
          value: { host: host.id },
          outbox: [{ kind: "host.delete", entity: host.id, payload: { id: host.id, team: state.team?.id } }]
        }
      }
      case "server.enrolled": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        return reduceServerEnrolled(state, params, ctx)
      }
      case "server.install_revoked": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceServerInstallRevoked(state, params)
      }
      case "server.revoke": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        return reduceServerRevoke(state, params, ctx)
      }
      case "team.policy.integration_seed": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        return withAudit(reduceIntegrationSeed(state, params, ctx), state.team.id, ctx, op)
      }
      case "team.policy.integration_lock": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceIntegrationLock(state, params)
      }
      case "team.integration.release_done": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceReleaseDone(state, params)
      }
      case "domain.claim": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot claim domains")
        const role = roleOf(state, ctx.rows, p.user)
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may claim domains")
        return withAudit(reduceDomainClaim(state, params, ctx), state.team.id, ctx, op)
      }
      case "sso.connection.create":
      case "sso.connection.disable": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot change SSO connections")
        const role = roleOf(state, ctx.rows, p.user)
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may change SSO connections")
        return withAudit(op === "sso.connection.create" ? reduceConnectionCreate(state, params, ctx) : reduceConnectionDisable(state, params, ctx), state.team.id, ctx, op)
      }
      case "sso.connection.set_secret":
      case "sso.connection.activate":
      case "domain.verify":
      case "domain.release":
        // External effects: only through the Worker's HTTP route (never the wire), so a secret is never an op param.
        return reject("validation.invalid", `${op} runs through POST /v1/ops only`)
      case "team_vm.ssh_ca_installed":
      case "team_vm.ssh_certs_revoked":
      case "team_vm.ssh_account_allocated": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        if (op === "team_vm.ssh_account_allocated") return reduceAccountAllocated(state, params, (u) => memberOf(state, ctx.rows, u))
        return op === "team_vm.ssh_ca_installed" ? reduceCaInstalled(state, state.team.id, params, ctx) : reduceCertsRevoked(state, state.team.id, params, ctx)
      }
      case "sso.signed_in": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        const q = params as { connection?: string; subject?: string; stack_user?: string; linked?: boolean }
        // Audit only; no state beyond the audit chain (identities live in the sso_identities side table).
        return withAudit({ ok: true, state, value: { connection: q.connection }, audit: { summary: q.linked ? `first SSO sign-in through ${q.connection}` : `SSO sign-in through ${q.connection}`, detail: q } }, state.team.id, ctx, op)
      }
      case "sso.connection.secret_set":
      case "sso.connection.activated": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        return withAudit(op === "sso.connection.secret_set" ? reduceSecretSet(state, params, ctx) : reduceActivated(state, params, ctx), state.team.id, ctx, op)
      }
      case "domain.rechecked": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        return withAudit(reduceDomainRechecked(state, params), state.team.id, ctx, op)
      }
      case "domain.mark_verified":
      case "domain.mark_released":
      case "domain.mark_lost": {
        if (p.kind !== "system" || !state.team) return reject("auth.forbidden", "internal op")
        const r = op === "domain.mark_verified" ? reduceDomainVerified(state, params) : op === "domain.mark_lost" ? reduceDomainLost(state, params) : reduceDomainReleased(state, params)
        return withAudit(r, state.team.id, ctx, op)
      }
      case "team.integration.release_lock": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot release integration locks")
        const role = roleOf(state, ctx.rows, p.user)
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may release an integration lock")
        return withAudit(reduceReleaseLock(state, params, ctx), state.team.id, ctx, op)
      }
      case "team.policy.integration_synced": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceIntegrationSynced(state, params)
      }
      case "team.policy.runs_synced": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceRunsSynced(state, params)
      }
      case "team.policy.update":
      case "team.policy.rollback":
      case "team.enrollment_token.create":
      case "team.enrollment_token.revoke": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        // Muxes change policy only through an approval flow (identity spec 4a), which does not exist yet.
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot change team policy or enrollment")
        const role = roleOf(state, ctx.rows, p.user)
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may change team policy or enrollment")
        if (op === "team.policy.update" || op === "team.policy.rollback") {
          const r = op === "team.policy.update" ? reducePolicyUpdate(state, params, ctx) : reducePolicyRollback(state, params, ctx)
          if (!r.ok || r.changed === false) return r
          const head = r.state.policy_history?.[0]
          const a = appendAudit(r.state, state.team.id, ctx, op, `policy v${head?.version}: ${head?.changed.join(", ")}`, {
            version: head?.version,
            changed: head?.changed,
            reason: head?.reason,
            rollback_of: head?.rollback_of,
            values: r.state.policy?.values
          })
          return { ok: true, state: a.state, value: r.value, outbox: [a.outbox] }
        }
        const r = op === "team.enrollment_token.create" ? reduceTokenCreate(state, params, ctx) : reduceTokenRevoke(state, params, ctx)
        return withAudit(r, state.team.id, ctx, op)
      }
      case "team.device.enroll": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot enroll devices")
        return withAudit(reduceDeviceEnroll(state, params, ctx, p.email), state.team.id, ctx, op)
      }
      case "team.device.report_status": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot report device status")
        return reduceReportStatus(state, params, ctx)
      }
      case "team.device.release": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        const role = roleOf(state, ctx.rows, p.user)
        return withAudit(reduceDeviceRelease(state, params, ctx, role === "owner" || role === "admin"), state.team.id, ctx, op)
      }
      default:
        return reject("validation.invalid", `unknown op ${op}`)
    }
  }
}

type Audited<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & import("@cmux/ownership").Reject)

/** Appends the audit record a committed admin action carries (spec/enterprise.md 6). */
const withAudit = (r: Audited<TeamState>, team: string, ctx: import("@cmux/ownership").ReduceContext, op: string) => {
  if (!r.ok || r.changed === false || !r.audit) {
    if (!r.ok) return r
    const { audit: _a, ...rest } = r
    return rest
  }
  const a = appendAudit(r.state, team, ctx, op, r.audit.summary, r.audit.detail)
  return { ok: true as const, state: a.state, value: r.value, outbox: [a.outbox] }
}

/** The head without a legacy host entry (a head before team.rows_migrate). */
const withoutLegacyHost = <S extends LegacyTeamMaps>(state: S, id: string): S => {
  if (!state.hosts?.[id]) return state
  const { [id]: _gone, ...hosts } = state.hosts
  return { ...state, hosts }
}
