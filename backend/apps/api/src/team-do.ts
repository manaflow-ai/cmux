import type { EventFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { teamEventVisible, teamSubscriberView } from "./domains/team-visibility.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { complianceFor, devicePolicyFor, publicToken } from "./domains/team-enrollment.ts"
import { integrationSyncPending, releasePending, sliceHash, type IntegrationFields } from "./domains/team-integration-sync.ts"
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
        // integration_managed_by: ConnectionDO holds an SSO or MDM lock that overrides TeamPolicy's integration keys (E2).
        return { ok: true, value: { team: state.team?.id, policy, integration_managed_by: state.integration_managed_by ?? null }, revision: "" }
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
      case "team.device.compliance": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may read device compliance" }
        return { ok: true, value: { team: state.team?.id, ...complianceFor(state) }, revision: "" }
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
    if (!state.team || (!integrationSyncPending(state) && !releasePending(state))) return null
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
    if (!state?.team || (!integrationSyncPending(state) && !releasePending(state))) return
    if (this.syncRetryAt !== null && now < this.syncRetryAt) return
    const team = state.team.id
    const stub = this.env.CONNECTION_DO.get(this.env.CONNECTION_DO.idFromName(team))
    try {
      if (releasePending(state)) {
        // An admin released the SSO/MDM lock (audited in team.integration.release_lock). ConnectionDO's
        // lock notice then comes back through integrationLockChanged and TeamDO pushes its policy.
        const request = state.integration_release_requested ?? 0
        const r = (await stub.releaseManagedLock(team, `team_policy:release:${request}`, `release-lock:${team}:${request}`)) as { ok: boolean; message?: string }
        if (!r.ok) throw new Error(`release refused: ${r.message}`)
        this.requireCommitted(this.submitSystem("team.integration.release_done", { request }, `release-done:${request}`))
        state = this.boundEngine!.currentState
        if (!integrationSyncPending(state)) return this.resetSyncBackoff()
      }
      if (!state.integration_seeded) {
        const adopted = (await stub.adoptIntegrationPolicy(team)) as { ok: true; policy: IntegrationFields; managed_by: "sso" | "mdm" | null } | { ok: false; message: string }
        if (!adopted.ok) throw new Error(`adopt refused: ${adopted.message}`)
        this.requireCommitted(this.submitSystem("team.policy.integration_seed", { policy: adopted.policy, managed_by: adopted.managed_by }, `integration-seed:v2:${team}`))
        state = this.boundEngine!.currentState
        if (!state.integration_seeded) throw new Error("seed did not commit")
        if (!integrationSyncPending(state)) return this.resetSyncBackoff()
      }
      const policy = currentPolicy(state)
      const slice = integrationSlice(policy.values)
      // The same version is pushed again after a lock change, so keys carry ConnectionDO's lock version.
      const lockVersion = state.integration_lock_version ?? 0
      const r = (await stub.applyTeamPolicy(team, { policy: slice, applied_by: `team_policy:v${policy.version}` }, `team-policy:v3:${team}:v${policy.version}:l${lockVersion}`)) as { ok: boolean; message?: string; managed_by: "sso" | "mdm" | null }
      if (!r.ok) throw new Error(r.message ?? "refused")
      // Under an SSO or MDM lock nothing changed in ConnectionDO; the version is still settled (no retry loop) and reported.
      this.requireCommitted(this.submitSystem("team.policy.integration_synced", { version: policy.version, slice_hash: sliceHash(slice), managed_by: r.managed_by }, `integration-synced:v4:${policy.version}:l${lockVersion}`))
      this.resetSyncBackoff()
    } catch (e) {
      this.syncAttempts += 1
      this.syncRetryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.syncAttempts)
      throw e
    }
  }

  /** A rejected system op must back off, not re-fire the alarm at once (review P2-1). */
  private requireCommitted(res: { frames: ReadonlyArray<OwnerFrame> }) {
    const rej = res.frames.find((f) => f.t === "reject")
    if (rej && rej.t === "reject") throw new Error(`${rej.code}: ${rej.message}`)
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

  /**
   * RPC from ConnectionDO: its SSO/MDM lock changed (appeared, changed source,
   * released). Recorded by version, so a late or repeated notice changes nothing.
   */
  async integrationLockChanged(team: string, managedBy: "sso" | "mdm" | null, version: number): Promise<{ ok: boolean; message?: string }> {
    this.bind(team)
    const res = this.submitSystem("team.policy.integration_lock", { managed_by: managedBy, version }, `integration-lock:${version}`)
    const rej = res.frames.find((f) => f.t === "reject")
    return rej && rej.t === "reject" ? { ok: false, message: rej.message } : { ok: true }
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
