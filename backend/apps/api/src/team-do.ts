import type { EventFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { teamEventVisible, teamSubscriberView } from "./domains/team-visibility.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { complianceFor, devicePolicyFor, publicToken } from "./domains/team-enrollment.ts"
import { integrationSyncPending, releasePending, sliceHash, type IntegrationFields } from "./domains/team-integration-sync.ts"
import { currentPolicy, integrationSlice, POLICY_HISTORY_LIMIT, policyAt } from "./domains/team-policy.ts"
import { domainExternal, RESOLVERS, txtAnswers, type DomainReply, type Http } from "./team-domain-external.ts"
import { nextRecheckAt, txtContains } from "./domains/team-domains.ts"
import { ssoExternal } from "./team-sso-external.ts"
import { connectionForDomain } from "./domains/team-sso.ts"

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
      case "sso.connection.list": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may list SSO connections" }
        return { ok: true, value: { team: state.team?.id, connections: Object.values(state.sso_connections ?? {}) }, revision: "" }
      }
      case "domain.list": {
        if (member.role !== "owner" && member.role !== "admin") return { ok: false, code: "auth.forbidden", message: "only team owners and admins may list domains" }
        return { ok: true, value: { team: state.team?.id, domains: Object.values(state.domains ?? {}) }, revision: "" }
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
    if (!state.team) return null
    const recheck = nextRecheckAt(state)
    const sync = integrationSyncPending(state) || releasePending(state) ? Math.max(now, this.syncRetryAt ?? now) : null
    return sync === null ? recheck : recheck === null ? sync : Math.min(sync, recheck)
  }

  /**
   * Seeds TeamPolicy from ConnectionDO's current integration policy once,
   * then pushes the integration slice only when it changed, and records the
   * acknowledged slice. Every step is idempotent (seed once, push keyed by
   * version, synced by version and hash), so a crash between steps replays.
   */
  protected override async onWake(now: number): Promise<void> {
    await this.recheckDomains(now)
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
        const r = (await stub.releaseManagedLock(team, state.integration_release_by ?? `team_policy:release:${request}`, `release-lock:${team}:${request}`)) as { ok: boolean; message?: string }
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
      const lockEpoch = state.integration_lock_epoch ?? ""
      const r = (await stub.applyTeamPolicy(team, { policy: slice, applied_by: `team_policy:v${policy.version}` }, `team-policy:v4:${team}:v${policy.version}:${lockEpoch}:l${lockVersion}`)) as { ok: boolean; message?: string; managed_by: "sso" | "mdm" | null }
      if (!r.ok) throw new Error(r.message ?? "refused")
      // Under an SSO or MDM lock nothing changed in ConnectionDO; the version is still settled (no retry loop) and reported.
      this.requireCommitted(this.submitSystem("team.policy.integration_synced", { version: policy.version, slice_hash: sliceHash(slice), managed_by: r.managed_by, lock_version: lockVersion, lock_epoch: lockEpoch }, `integration-synced:v5:${policy.version}:${lockEpoch}:l${lockVersion}`))
      this.resetSyncBackoff()
    } catch (e) {
      this.syncAttempts += 1
      this.syncRetryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.syncAttempts)
      throw e
    }
  }

  /**
   * Weekly DNS re-check of verified domains (spec 3.4). Every attempt records
   * its time, so a failing resolver cannot spin the alarm. On the third failure
   * DomainDO frees the domain first (so a new owner can verify), then the
   * domain becomes lapsed.
   */
  private async recheckDomains(now: number) {
    const state = this.boundEngine?.currentState
    if (!state?.team) return
    const team = state.team.id
    const due = Object.values(state.domains ?? {}).filter((d) => d.state === "verified" && (d.last_checked_at ?? d.verified_at ?? d.requested_at) + 7 * 86_400_000 <= now)
    for (const d of due.slice(0, 5)) {
      const results = await Promise.all(RESOLVERS.map((r) => txtAnswers(this.http, r(d.record_name))))
      const ok = results.every((answers) => txtContains(answers, d.record_value))
      if (!ok && (d.check_failures ?? 0) + 1 >= 3) await this.env.DOMAIN_DO.get(this.env.DOMAIN_DO.idFromName(d.domain)).release(team)
      this.submitSystem("domain.rechecked", { domain: d.domain, record_value: d.record_value, ok, at: now }, `domain-recheck:${d.domain}:${now}`)
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
  async integrationLockChanged(team: string, managedBy: "sso" | "mdm" | null, version: number, epoch: string): Promise<{ ok: boolean; message?: string }> {
    this.bind(team)
    const res = this.submitSystem("team.policy.integration_lock", { managed_by: managedBy, version, epoch }, `integration-lock:${epoch}:${version}`)
    const rej = res.frames.find((f) => f.t === "reject")
    return rej && rej.t === "reject" ? { ok: false, message: rej.message } : { ok: true }
  }

  /** Outbound fetch for DNS over HTTPS; tests replace it. */
  http: Http = (r) => fetch(r)

  /** RPC from the Worker: domain.verify and domain.release (DNS and DomainDO, then a system op). */
  async domainOp(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> {
    const engine = this.bind(entity)
    return domainExternal(
      {
        state: engine.currentState,
        team: entity,
        stream: engine.stream,
        http: this.http,
        domainStub: (domain) => this.env.DOMAIN_DO.get(this.env.DOMAIN_DO.idFromName(domain)),
        submitSystem: (op, params, key) => this.submitSystem(op, params, key),
        now: Date.now()
      },
      principal,
      frame
    )
  }

  /** RPC from the Worker: sso.connection.set_secret and sso.connection.activate (sealing, OIDC discovery). */
  async ssoOp(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> {
    const engine = this.bind(entity)
    return ssoExternal(
      {
        state: engine.currentState,
        team: entity,
        stream: engine.stream,
        http: this.http,
        kek: this.env.INTEGRATIONS_KEK,
        sql: this.ctx.storage.sql,
        submitSystem: (op, params, key) => this.submitSystem(op, params, key)
      },
      principal,
      frame
    )
  }

  /**
   * RPC from sign-in discovery (unauthenticated): whether this team serves
   * `domain` through an active connection. Answers only yes or no, never the
   * team or the connection, so discovery does not enumerate customers.
   */
  async ssoDiscover(entity: string, domain: string): Promise<{ sso: boolean }> {
    const engine = this.boundEngine ?? this.bind(entity)
    return { sso: Boolean(connectionForDomain(engine.currentState, domain)) }
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }
}
