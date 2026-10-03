import type { Domain } from "@cmux/ownership"
import { HostEnroll, HostRemove, type Host, type TeamMember } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"
import { appendAudit, type AuditState } from "./team-audit.ts"
import { reduceDomainClaim, reduceDomainLost, reduceDomainRechecked, reduceDomainReleased, reduceDomainVerified, type DomainState } from "./team-domains.ts"
import { reduceActivated, reduceConnectionCreate, reduceConnectionDisable, reduceSecretSet, type SsoState } from "./team-sso.ts"
import { reduceDeviceEnroll, reduceDeviceRelease, reduceReportStatus, reduceTokenCreate, reduceTokenRevoke, type EnrollmentState } from "./team-enrollment.ts"
import { reduceIntegrationLock, reduceIntegrationSeed, reduceIntegrationSynced, reduceReleaseDone, reduceReleaseLock, type IntegrationSyncState } from "./team-integration-sync.ts"
import { reducePolicyRollback, reducePolicyUpdate } from "./team-policy.ts"
import { reduceAccountAllocated, reduceCaInstalled, reduceCertsRevoked, type TeamSshState } from "./team-ssh.ts"
import { reduceServerEnrolled, reduceServerInstallRevoked, reduceServerRevoke, type ServerRevocation } from "./team-servers.ts"

export interface TeamState extends EnrollmentState, AuditState, IntegrationSyncState, DomainState, SsoState, TeamSshState {
  readonly team: { readonly id: string; readonly kind: "personal" | "stack"; readonly display_name: string } | null
  readonly members: Readonly<Record<string, typeof TeamMember.Type>>
  readonly hosts: Readonly<Record<string, typeof Host.Type>>
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
  initial: () => ({ team: null, members: {}, hosts: {} }),

  authorize: (state, op, _params, principal) => {
    // HTTP-only ops (external effects; a secret in params): refused before the ledger, which would
    // otherwise keep an unsalted hash of the params (review P2). They run through the Worker's route.
    if (HTTP_ONLY_OPS.has(op)) return { code: "validation.invalid", message: `${op} runs through POST /v1/ops only` }
    // TeamDO's own ops (alarm work); admit allows a system principal only for internal ops.
    if (principal.kind === "system") return admit("cloud:TeamDO", op, principal, () => undefined, Date.now())
    if (op !== "team.ensure_personal") {
      if (!principal.user || !state.members[principal.user]) return { code: "auth.forbidden", message: "not a member of this team" }
    }
    // The grant lives in UserDO. The Worker asks UserDO on every install call
    // (revocation and grant) and passes the grant's classes; none means refuse.
    return admit("cloud:TeamDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (state, op, params, ctx) => {
    const p = ctx.principal
    switch (op) {
      case "team.ensure_personal": {
        if (!p.user || !p.team) return reject("auth.forbidden", "needs a user session")
        if (state.team && state.team.id !== p.team) return reject("auth.forbidden", "not this team")
        const name = p.display_name ?? "Personal"
        const member: typeof TeamMember.Type = { user: p.user, role: "owner", display_name: name }
        const team = { id: p.team, kind: "personal" as const, display_name: name }
        const same = JSON.stringify(state.team) === JSON.stringify(team) && JSON.stringify(state.members[p.user]) === JSON.stringify(member)
        if (same) return { ok: true, state, value: team, changed: false }
        return {
          ok: true,
          state: { ...state, team, members: { ...state.members, [p.user]: member } },
          value: team,
          outbox: [
            { kind: "team.upsert", entity: team.id, payload: team },
            { kind: "membership.upsert", entity: `${team.id}:${p.user}`, payload: { team: team.id, ...member } }
          ]
        }
      }
      case "host.enroll": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        const d = decodeParams<typeof HostEnroll.params.Type>(HostEnroll, params)
        if (!d.ok) return d
        if (!p.install || !p.user) return reject("auth.forbidden", "host.enroll needs an install token")
        const existing = Object.values(state.hosts).find((h) => h.enrolled_by === p.install)
        const id = existing?.id ?? ctx.newId("host")
        const host: typeof Host.Type = { id, name: d.value.name, platform: d.value.platform, owner_user: p.user, enrolled_by: p.install, enrolled_at: existing?.enrolled_at ?? ctx.now }
        if (existing && JSON.stringify(existing) === JSON.stringify(host)) return { ok: true, state, value: host, changed: false }
        return {
          ok: true,
          state: { ...state, hosts: { ...state.hosts, [id]: host } },
          value: host,
          outbox: [{ kind: "host.upsert", entity: id, payload: { ...host, team: state.team.id } }]
        }
      }
      case "host.remove": {
        const d = decodeParams<typeof HostRemove.params.Type>(HostRemove, params)
        if (!d.ok) return d
        const host = state.hosts[d.value.host]
        if (!host) return reject("selector.not_found", "host not found")
        const role = p.user ? state.members[p.user]?.role : undefined
        if (host.owner_user !== p.user && role !== "owner" && role !== "admin") return reject("auth.forbidden", "only the host owner or a team admin may remove it")
        const { [host.id]: _gone, ...rest } = state.hosts
        return {
          ok: true,
          state: { ...state, hosts: rest },
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
        const role = p.user ? state.members[p.user]?.role : undefined
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may claim domains")
        return withAudit(reduceDomainClaim(state, params, ctx), state.team.id, ctx, op)
      }
      case "sso.connection.create":
      case "sso.connection.disable": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot change SSO connections")
        const role = p.user ? state.members[p.user]?.role : undefined
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
        if (op === "team_vm.ssh_account_allocated") return reduceAccountAllocated(state, params)
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
        const role = p.user ? state.members[p.user]?.role : undefined
        if (role !== "owner" && role !== "admin") return reject("auth.forbidden", "only team owners and admins may release an integration lock")
        return withAudit(reduceReleaseLock(state, params, ctx), state.team.id, ctx, op)
      }
      case "team.policy.integration_synced": {
        if (p.kind !== "system") return reject("auth.forbidden", "internal op")
        return reduceIntegrationSynced(state, params)
      }
      case "team.policy.update":
      case "team.policy.rollback":
      case "team.enrollment_token.create":
      case "team.enrollment_token.revoke": {
        if (!state.team) return reject("validation.invalid", "team not initialized")
        // Muxes change policy only through an approval flow (identity spec 4a), which does not exist yet.
        if (p.kind === "agent" || p.agent) return reject("auth.forbidden", "agents cannot change team policy or enrollment")
        const role = p.user ? state.members[p.user]?.role : undefined
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
        const role = p.user ? state.members[p.user]?.role : undefined
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
