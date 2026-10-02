import type { Domain } from "@cmux/ownership"
import { HostEnroll, HostRemove, type Host, type TeamMember } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"
import { appendAudit, type AuditState } from "./team-audit.ts"
import { reduceDeviceEnroll, reduceDeviceRelease, reduceReportStatus, reduceTokenCreate, reduceTokenRevoke, type EnrollmentState } from "./team-enrollment.ts"
import { reduceIntegrationLock, reduceIntegrationSeed, reduceIntegrationSynced, reduceReleaseDone, reduceReleaseLock, type IntegrationSyncState } from "./team-integration-sync.ts"
import { reducePolicyRollback, reducePolicyUpdate } from "./team-policy.ts"

export interface TeamState extends EnrollmentState, AuditState, IntegrationSyncState {
  readonly team: { readonly id: string; readonly kind: "personal" | "stack"; readonly display_name: string } | null
  readonly members: Readonly<Record<string, typeof TeamMember.Type>>
  readonly hosts: Readonly<Record<string, typeof Host.Type>>
}

/**
 * TeamDO's reducer: the account directory (U2). Phase 1 knows personal teams
 * only; Stack teams arrive by webhook ops once the Stack webhook is configured.
 * Grants for team ops are checked by UserDO when it mints the token; TeamDO
 * checks membership and the op's principal kind.
 */
export const teamDomain: Domain<TeamState> = {
  initial: () => ({ team: null, members: {}, hosts: {} }),

  authorize: (state, op, _params, principal) => {
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
