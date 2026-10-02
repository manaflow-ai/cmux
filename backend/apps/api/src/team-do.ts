import type { EventFrame, Principal } from "@cmux/ownership"
import { teamEventVisible, teamSubscriberView } from "./domains/team-visibility.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { devicePolicyFor, publicToken } from "./domains/team-enrollment.ts"
import { integrationSyncPending, sliceHash, type IntegrationFields } from "./domains/team-integration-sync.ts"
import { currentPolicy, integrationSlice, POLICY_HISTORY_LIMIT, policyAt } from "./domains/team-policy.ts"

/** TeamDO: membership cache and the account directory of hosts (U2). */
export class TeamDO extends OwnerDO<TeamState> {
  constructor(ctx: DurableObjectState, env: Env) {
    // Members see each other's public ids and display name in events, never email,
    // Stack id, grant or token data.
    super(ctx, env, teamDomain, "team", (p) => ({
      identity: p.kind === "system" ? p.identity : (p.install ?? `user:${p.user}`),
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.team ? { team: p.team } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.display_name ? { display_name: p.display_name } : {})
    }))
  }

  protected read(state: TeamState, op: string, params: unknown, principal: Principal): ReadResult {
    const member = principal.user ? state.members[principal.user] : undefined
    if (!member) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    const p = (params ?? {}) as { version?: unknown; limit?: unknown }
    switch (op) {
      case "team.directory":
        return { ok: true, value: { team: state.team?.id, members: Object.values(state.members), hosts: Object.values(state.hosts) }, revision: "" }
      case "team.policy.get": {
        if (p.version !== undefined && (typeof p.version !== "number" || !Number.isInteger(p.version))) return { ok: false, code: "validation.invalid", message: "version must be an integer" }
        const policy = policyAt(state, p.version as number | undefined)
        if (!policy) return { ok: false, code: "selector.not_found", message: `policy version ${String(p.version)} is not retained` }
        return { ok: true, value: { team: state.team?.id, policy }, revision: "" }
      }
      case "team.policy.history": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may read policy history" }
        const limit = typeof p.limit === "number" && Number.isInteger(p.limit) ? Math.min(Math.max(p.limit, 1), POLICY_HISTORY_LIMIT) : 20
        return { ok: true, value: { team: state.team?.id, versions: (state.policy_history ?? []).slice(0, limit) }, revision: "" }
      }
      case "team.enrollment_token.list": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may list enrollment tokens" }
        return {
          ok: true,
          value: { team: state.team?.id, tokens: Object.values(state.enrollment_tokens ?? {}).map(publicToken), devices: Object.values(state.managed_devices ?? {}) },
          revision: ""
        }
      }
      case "team.device.policy": {
        const d = devicePolicyFor(state, principal.install)
        return { ok: true, value: { team: state.team?.id, team_name: state.team?.display_name ?? "", ...d }, revision: "" }
      }
      default:
        return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    }
  }

  /** Backoff after a failed push to ConnectionDO (in memory: a restart retries at once). */
  private syncRetryAt: number | null = null
  private syncAttempts = 0

  /** Wake while ConnectionDO lacks the current policy version (spec/enterprise.md 4.6). */
  protected override nextWakeAt(state: TeamState, now: number): number | null {
    if (!state.team || !integrationSyncPending(state)) return null
    return Math.max(now, this.syncRetryAt ?? now)
  }

  /**
   * Seeds TeamPolicy from ConnectionDO's current integration policy once,
   * then pushes the integration slice only when it changed, and records the
   * acknowledged slice. Every step is idempotent (seed once, push keyed by
   * version, synced by version and hash), so a crash between steps replays.
   */
  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    let state = engine?.currentState
    if (!state?.team || !integrationSyncPending(state)) return
    if (this.syncRetryAt !== null && now < this.syncRetryAt) return
    const team = state.team.id
    const stub = this.env.CONNECTION_DO.get(this.env.CONNECTION_DO.idFromName(team))
    try {
      if (!state.integration_seeded) {
        const existing = (await stub.integrationPolicy(team)) as IntegrationFields
        this.submitSystem("team.policy.integration_seed", { policy: existing }, `integration-seed:${team}`)
        state = this.boundEngine!.currentState
        if (!integrationSyncPending(state)) return this.resetSyncBackoff()
      }
      const policy = currentPolicy(state)
      const slice = integrationSlice(policy.values)
      const r = (await stub.applyTeamPolicy(team, { policy: slice, applied_by: `team_policy:v${policy.version}` }, `team-policy:${team}:v${policy.version}`)) as { ok: boolean; message?: string }
      if (!r.ok) throw new Error(r.message ?? "refused")
      this.submitSystem("team.policy.integration_synced", { version: policy.version, slice_hash: sliceHash(slice) }, `integration-synced:${policy.version}`)
      this.resetSyncBackoff()
    } catch (e) {
      this.syncAttempts += 1
      this.syncRetryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.syncAttempts)
      throw e
    }
  }

  private resetSyncBackoff() {
    this.syncAttempts = 0
    this.syncRetryAt = null
  }

  protected override subscriberView(state: TeamState, principal: Principal): unknown {
    return teamSubscriberView(state, principal)
  }

  protected override mayReceive(state: TeamState, event: EventFrame, principal: Principal): boolean {
    return teamEventVisible(state, event, principal)
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
