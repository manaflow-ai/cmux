import type { Principal } from "@cmux/ownership"
import type { TeamState } from "./domains/team.ts"
import { complianceFor, devicePolicyFor, publicToken } from "./domains/team-enrollment.ts"
import { POLICY_HISTORY_LIMIT, policyAt } from "./domains/team-policy.ts"
import { accountsView, sshCaView } from "./domains/team-ssh.ts"
import type { ReadResult } from "./owner-do.ts"
import { listHosts, listMembers, memberOf, type Member, type RowsWithScan } from "./domains/team-members.ts"
import { ROLES, roleHas, type TeamGrant } from "./domains/team-roles.ts"
import { noOwnerOf, seatsOf } from "./domains/team-stack.ts"
import { auditPage } from "./domains/team-audit-rows.ts"
import { aiLimitViewOf } from "./domains/team-ai-limit.ts"
import { groupRead } from "./domains/team-group-reads.ts"
import type { Env } from "./env.ts"
import { nextMonthStart } from "./usage-user.ts"
import { teamUsageLine } from "./team-ai-usage.ts"

const DIRECTORY_PAGE = 200

/** The grant each read needs (team-roles.ts); team_vm.accounts also admits the team VM's install (checked in its case). */
const READ_GRANTS: Readonly<Record<string, TeamGrant>> = {
  "team.directory": "team.resources",
  // The policy a member's devices follow (review P3-5): no default grant for guests or billing.
  "team.policy.get": "team.resources",
  "team.device.policy": "team.resources",
  "team.members.list": "team.resources",
  "team.hosts.list": "team.resources",
  "team.policy.history": "team.manage",
  "team.enrollment_token.list": "team.manage",
  "sso.connection.list": "team.manage",
  "domain.list": "team.manage",
  "team.device.compliance": "team.manage",
  "team.audit.list": "audit.read_billing",
  "group.get": "team.resources",
  "group.list": "team.resources"
}

/** TeamDO reads (members only; admin reads for owners and admins). Pure over the team state. */
export const teamRead = (state: TeamState, op: string, params: unknown, principal: Principal, rows?: RowsWithScan): ReadResult => {
  const member = memberOf(state, rows, principal.user)
  if (!member) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
  const p = (params ?? {}) as { version?: unknown; limit?: unknown }
  // Grants, never role names (team-roles.ts): only the public CA (team_vm.ssh_ca) needs none.
  const needs = READ_GRANTS[op]
  if (needs && !roleHas(member.role, needs)) return { ok: false, code: "auth.forbidden", message: `the ${member.role} role may not read ${op}` }
  switch (op) {
    case "team.directory":
      // The first page of each list (old clients); team.members.list and team.hosts.list page the rest.
      return { ok: true, value: { team: state.team?.id, members: listMembers(state, rows, undefined, DIRECTORY_PAGE).items, hosts: listHosts(state, rows, undefined, DIRECTORY_PAGE).items }, revision: "" }
    case "team.members.list": {
      const q = params as { cursor?: unknown; limit?: unknown; role?: unknown } | null
      const limit = typeof q?.limit === "number" && Number.isInteger(q.limit) ? Math.min(Math.max(q.limit, 1), DIRECTORY_PAGE) : DIRECTORY_PAGE
      const cursor = typeof q?.cursor === "string" && q.cursor.length <= 128 ? q.cursor : undefined
      const role = ROLES.find((r) => r === q?.role)
      // A role filter scans forward in bounded steps, so a page is never empty while matches remain.
      const out: Array<Member> = []
      let after = cursor
      let next: string | null = null
      for (let steps = 0; steps < 20 && out.length < limit; steps++) {
        const pageOf = listMembers(state, rows, after, limit)
        for (const m of pageOf.items) if (!role || m.role === role) out.length < limit && out.push(m)
        next = pageOf.next
        if (next === null) break
        after = next
      }
      const last = out.at(-1)?.user
      return { ok: true, value: { team: state.team?.id, members: out, member_count: state.member_count ?? out.length, seat_count: seatsOf(state), no_owner: noOwnerOf(state), next_cursor: out.length < limit && next === null ? null : (last ?? next) }, revision: "" }
    }
    case "team.hosts.list": {
      const q = params as { cursor?: unknown; limit?: unknown } | null
      const limit = typeof q?.limit === "number" && Number.isInteger(q.limit) ? Math.min(Math.max(q.limit, 1), DIRECTORY_PAGE) : DIRECTORY_PAGE
      const pageOf = listHosts(state, rows, typeof q?.cursor === "string" && q.cursor.length <= 128 ? q.cursor : undefined, limit)
      return { ok: true, value: { team: state.team?.id, hosts: pageOf.items, host_count: state.host_count ?? pageOf.items.length, next_cursor: pageOf.next }, revision: "" }
    }
    case "team.policy.get": {
      if (p.version !== undefined && (typeof p.version !== "number" || !Number.isInteger(p.version))) return { ok: false, code: "validation.invalid", message: "version must be an integer" }
      const policy = policyAt(state, p.version as number | undefined)
      if (!policy) return { ok: false, code: "selector.not_found", message: `policy version ${String(p.version)} is not retained` }
      // integration_managed_by: ConnectionDO holds an SSO or MDM lock that overrides TeamPolicy's integration keys (E2).
      return { ok: true, value: { team: state.team?.id, policy, integration_managed_by: state.integration_managed_by ?? null }, revision: "" }
    }
    case "team.policy.history": {
      const limit = typeof p.limit === "number" && Number.isInteger(p.limit) ? Math.min(Math.max(p.limit, 1), POLICY_HISTORY_LIMIT) : 20
      return { ok: true, value: { team: state.team?.id, versions: (state.policy_history ?? []).slice(0, limit) }, revision: "" }
    }
    case "team.enrollment_token.list": {
      return {
        ok: true,
        value: { team: state.team?.id, tokens: Object.values(state.enrollment_tokens ?? {}).map(publicToken), devices: Object.values(state.managed_devices ?? {}) },
        revision: ""
      }
    }
    case "sso.connection.list": {
      return { ok: true, value: { team: state.team?.id, connections: Object.values(state.sso_connections ?? {}) }, revision: "" }
    }
    case "domain.list": {
      return { ok: true, value: { team: state.team?.id, domains: Object.values(state.domains ?? {}) }, revision: "" }
    }
    case "team.device.compliance": {
      return { ok: true, value: { team: state.team?.id, ...complianceFor(state) }, revision: "" }
    }
    case "team.device.policy": {
      const d = devicePolicyFor(state, principal.install)
      return { ok: true, value: { team: state.team?.id, team_name: state.team?.display_name ?? "", ...d }, revision: "" }
    }
    case "team_vm.ssh_ca":
      // Public material only: CA public keys and the revocation list, for the team VM's sshd.
      return { ok: true, value: sshCaView(state.team?.id ?? "", state, Date.now()), revision: String(state.ssh_krl?.version ?? 0) }
    case "team_vm.accounts": {
      // The VM's reconciler (its own install) and the team's owners and admins; nobody else (deny by default).
      const teamVm = principal.kind === "install" && principal.install_kind === "team-vm"
      const admin = principal.kind === "session" && roleHas(member.role, "team.manage")
      if (!teamVm && !admin) return { ok: false, code: "auth.forbidden", message: "only the team VM and the team's owners and admins may read its Linux accounts" }
      return { ok: true, value: accountsView(state.team?.id ?? "", state, (user) => memberOf(state, rows, user) !== undefined), revision: String(state.vm_next_uid ?? 0) }
    }
    case "team.ai_limit.get": {
      // The caller's own limit; every member's only for billing.manage (team-ai-limit.ts). Spend is added by withAiSpend.
      const q = params as { cursor?: unknown } | null
      const v = aiLimitViewOf(state, rows, state.team?.id ?? "", principal.user ?? "", typeof q?.cursor === "string" ? q.cursor : undefined, principal.kind === "session" && !principal.agent)
      if (!v.ok) return { ok: false, code: v.code, message: v.message }
      const { ok: _ok, ...value } = v
      return { ok: true, value, revision: String(state.audit_count ?? 0) }
    }
    case "team.audit.list": {
      // Session only (the op's principals); billing reads only billing records (spec H12 b).
      const q = params as { before?: unknown; limit?: unknown } | null
      const limit = typeof q?.limit === "number" && Number.isInteger(q.limit) ? Math.min(Math.max(q.limit, 1), DIRECTORY_PAGE) : 50
      const before = typeof q?.before === "number" && Number.isInteger(q.before) ? q.before : undefined
      const page = auditPage(rows, before, limit, roleHas(member.role, "audit.read") ? undefined : "billing")
      return { ok: true, value: { team: state.team?.id, ...page }, revision: String(state.audit_count ?? 0) }
    }
    case "group.get":
    case "group.list":
      return groupRead(state, op, params, principal.user!, rows)
    default:
      return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
  }
  }

/**
 * cx-n3fb: the team VM's own install reads `team_vm.accounts` only while it is the install TeamVmDO
 * bound for the current epoch (`current`); an older epoch's install, another install or a team
 * without a VM record is refused. An unreachable TeamVmDO fails closed. Null: the read may answer.
 */
export const teamVmAccountsFence = async (current: () => Promise<string | null>, principal: Principal, op: string): Promise<ReadResult | null> => {
  if (op !== "team_vm.accounts" || principal.kind !== "install" || principal.install_kind !== "team-vm") return null
  let install: string | null
  try {
    install = await current()
  } catch {
    return { ok: false, code: "owner.unreachable", message: "the team VM record did not answer; try again" }
  }
  return install !== null && install === principal.install ? null : { ok: false, code: "team_vm.stale_epoch", message: "this install is not the team VM's install for the current epoch" }
}

/**
 * team.ai_limit.get, the Worker-side half (TeamDO.readOp): this month's spend from the team's
 * UsageMeterDO for exactly the users the view lists (the caller, and members for billing.manage),
 * and the UTC month's reset time; for billing.manage readers also the team line (team-ai-usage.ts) from
 * the stored plan copy `plan`. A meter failure leaves the limits and reports spend as unknown (-1).
 */
export const withAiSpend = async (env: Env, team: string, r: ReadResult, plan: string | null = null): Promise<ReadResult> => {
  if (!r.ok) return r
  const v = r.value as { me: { user: string }; members?: Array<{ user: string }> }
  const users = [v.me.user, ...(v.members ?? []).map((m) => m.user)]
  const spends = await env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team)).userSpends(team, users).catch(() => ({}) as Record<string, number>)
  const spent = (u: string) => spends[u] ?? -1
  // The team line (included amount, the stop) only beside the members list, i.e. for billing.manage readers.
  const line = v.members ? { team_usage: await teamUsageLine(env, team, plan) } : {}
  return { ...r, value: { ...v, ...line, resets_at: nextMonthStart(Date.now()), me: { ...v.me, spent_usd: spent(v.me.user) }, ...(v.members ? { members: v.members.map((m) => ({ ...m, spent_usd: spent(m.user) })) } : {}) } }
}
