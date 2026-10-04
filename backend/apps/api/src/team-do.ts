import type { EventFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { teamEventVisible, teamSubscriberView } from "./domains/team-visibility.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { teamRead } from "./team-reads.ts"
import { memberOf, roleOf, TABLE_MEMBER, TEAM_PRIVATE_TABLES } from "./domains/team-members.ts"
import { integrationSyncPending, releasePending, sliceHash, type IntegrationFields } from "./domains/team-integration-sync.ts"
import { runSyncPending, runSyncPush } from "./domains/team-run-sync.ts"
import { currentPolicy, enforcedOn, integrationSlice, ssoServable, type PolicyValues } from "./domains/team-policy.ts"
import { domainExternal, RESOLVERS, txtAnswers, type DomainReply, type Http } from "./team-domain-external.ts"
import { nextRecheckAt, RECHECK_MS, txtContains } from "./domains/team-domains.ts"
import { ssoExternal } from "./team-sso-external.ts"
import { ssoCallback, ssoMaxAgeMs, ssoSessionConnection, ssoRedeem, ssoStart, type LoginDeps } from "./team-sso-login.ts"
import { stackServer, type StackServer } from "./stack-server.ts"
import { connectionForDomain } from "./domains/team-sso.ts"
import { mayEnrollServer, type ServerEnrollRefused } from "./domains/team-servers.ts"
import { revokeInstallCerts, sshExternal } from "./team-ssh-ca.ts"
import type { SshPresence } from "./team-ssh-presence.ts"

/** TeamDO: membership cache and the account directory of hosts (U2). */
/** TeamDO.signInRules result (policy-gate.ts). */
export interface SignInRules {
  readonly sso_required: boolean
  readonly minimum_version: string | null
  readonly allowed_classes: ReadonlyArray<string>
}

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
    }), { rowMode: { snapshotTable: TABLE_MEMBER, snapshotTail: 0 }, redact: { privateTables: TEAM_PRIVATE_TABLES } })
  }

  /** Members and hosts are rows ((f)); an old head moves its maps there on the first bind. */
  protected override bind(entity: string) {
    const engine = super.bind(entity)
    if (engine.currentState.members !== undefined || engine.currentState.hosts !== undefined) this.submitSystem("team.rows_migrate", {}, "rows-migrate:v1")
    return engine
  }

  private get rows() {
    return this.boundEngine?.rows
  }

  protected read(state: TeamState, op: string, params: unknown, principal: Principal): ReadResult {
    return teamRead(state, op, params, principal, this.rows)
  }

  /** Backoff after a failed push to ConnectionDO (in memory: a restart retries at once). */
  private syncRetryAt: number | null = null
  private syncAttempts = 0

  /** Backoff after a failed run-policy push to SchedulerDO (in memory). */
  private runSyncRetryAt: number | null = null
  private runSyncAttempts = 0

  /** Wake while ConnectionDO lacks the current policy version (spec/enterprise.md 4.6) or SchedulerDO lacks the run class. */
  protected override nextWakeAt(state: TeamState, now: number): number | null {
    if (!state.team) return null
    if (Object.keys(state.server_revocations ?? {}).length > 0) return Math.max(now, this.revokeRetryAt ?? now)
    const times = [
      nextRecheckAt(state),
      integrationSyncPending(state) || releasePending(state) ? Math.max(now, this.syncRetryAt ?? now) : null,
      runSyncPending(state) ? Math.max(now, this.runSyncRetryAt ?? now) : null
    ].filter((t): t is number => t !== null)
    return times.length === 0 ? null : Math.min(...times)
  }

  /**
   * Pushes the run class of agents.allowedClasses to SchedulerDO (team-run-sync.ts), then records
   * the acknowledgement. Idempotent on both sides (keys carry the version and the bit). A failure
   * backs off and never blocks the integration push.
   */
  private async syncRunPolicy(now: number): Promise<void> {
    const state = this.boundEngine?.currentState
    if (!state?.team || !runSyncPending(state)) return
    if (this.runSyncRetryAt !== null && now < this.runSyncRetryAt) return
    const team = state.team.id
    const push = runSyncPush(state)
    try {
      const stub = this.env.SCHEDULER_DO.get(this.env.SCHEDULER_DO.idFromName(team)) as unknown as { applyRunPolicy(e: string, p: typeof push): Promise<{ ok: boolean; message?: string }> }
      const r = await stub.applyRunPolicy(team, push)
      if (!r.ok) throw new Error(r.message ?? "refused")
      this.requireCommitted(this.submitSystem("team.policy.runs_synced", push, `runs-synced:${push.version}:${push.runs_allowed ? 1 : 0}`))
      this.runSyncAttempts = 0
      this.runSyncRetryAt = null
    } catch (e) {
      this.runSyncAttempts += 1
      this.runSyncRetryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.runSyncAttempts)
      console.error(JSON.stringify({ msg: "run policy push to SchedulerDO failed", team, error: String(e) }))
    }
  }

  /**
   * Seeds TeamPolicy from ConnectionDO's current integration policy once,
   * then pushes the integration slice only when it changed, and records the
   * acknowledged slice. Every step is idempotent (seed once, push keyed by
   * version, synced by version and hash), so a crash between steps replays.
   */
  protected override async onWake(now: number): Promise<void> {
    if (this.revokeRetryAt === null || now >= this.revokeRetryAt) await this.flushServerRevocations(this.boundEngine?.currentState.team?.id ?? "")
    await this.recheckDomains(now)
    try {
      await this.syncIntegration(now)
    } finally {
      // After the integration push, so a slow SchedulerDO never delays it (review P3).
      await this.syncRunPolicy(now)
    }
  }

  /** RPC from SchedulerDO (fail closed): the run class as TeamDO would push it now. */
  async runPolicy(entity: string): Promise<{ version: number; runs_allowed: boolean }> {
    return runSyncPush(this.bind(entity).currentState)
  }

  private async syncIntegration(now: number): Promise<void> {
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
    const due = Object.values(state.domains ?? {}).filter((d) => d.state === "verified" && (d.last_checked_at ?? d.verified_at ?? d.requested_at) + RECHECK_MS <= now)
    for (const d of due.slice(0, 5)) {
      try {
        const domainDO = this.env.DOMAIN_DO.get(this.env.DOMAIN_DO.idFromName(d.domain))
        const results = await Promise.all(RESOLVERS.map((r) => txtAnswers(this.http, r(d.record_name))))
        // A resolver failure is "unknown": record the attempt time without counting a failure.
        const unknown = results.some((answers) => answers === null)
        const ok = unknown || results.every((answers) => answers !== null && txtContains(answers, d.record_value))
        this.requireCommitted(this.submitSystem("domain.rechecked", { domain: d.domain, record_value: d.record_value, ok, at: now }, `domain-recheck:${d.domain}:${now}`))
        const after = this.boundEngine!.currentState.domains?.[d.domain]
        // Commit first, then free: a lost release is retried by the next verify or re-check (release is idempotent);
        // a passing re-check re-asserts ownership, so TeamDO and DomainDO cannot drift apart for long.
        if (after?.state === "lapsed") await domainDO.release(team)
        else if (ok && !unknown) {
          const held = await domainDO.claim(d.domain, team, now)
          if (!held.ok) this.requireCommitted(this.submitSystem("domain.mark_lost", { domain: d.domain }, `domain-lost:${d.domain}:${d.record_value}:${now}`))
        }
      } catch (e) {
        console.error(JSON.stringify({ msg: "domain re-check failed", domain: d.domain, error: String(e) }))
      }
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
    return teamSubscriberView(state, principal, this.rows)
  }

  protected override mayReceive(state: TeamState, event: EventFrame, principal: Principal): boolean {
    return teamEventVisible(state, event, principal, this.rows)
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
        rows: engine.rows,
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
        rows: engine.rows,
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

  /** RPC from the Worker: team_vm.ssh_cert.challenge, team_vm.ssh_cert, team_vm.ssh_cert.revoke and team_vm.ssh_ca.rotate (the team SSH CA, team-ssh-ca.ts). */
  async sshOp(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> {
    const engine = this.bind(entity)
    return sshExternal(
      {
        state: () => this.boundEngine?.currentState ?? engine.currentState,
        rows: engine.rows,
        team: entity,
        stream: engine.stream,
        kek: this.env.INTEGRATIONS_KEK,
        sql: this.ctx.storage.sql,
        now: () => Date.now(),
        submitSystem: (op, params, key) => this.submitSystem(op, params, key),
        presence: this.presenceOwner(entity),
        running: this.sshRunning
      },
      principal,
      frame
    )
  }

  /** SSH CA requests running in this instance (team-ssh-ca.ts); a reset object starts with none, so its stored requests resume. */
  private readonly sshRunning = new Set<string>()

  /** The person's UserDO checks presence proofs (keys, nonces, App Attest counters live there); tests replace it. */
  presenceOwner = (team: string): SshPresence => ({
    challenge: (user, install, purpose) => this.env.USER_DO.get(this.env.USER_DO.idFromName(user)).presenceChallenge(user, team, install, purpose),
    assert: (user, proof, purpose) => this.env.USER_DO.get(this.env.USER_DO.idFromName(user)).presenceAssert(user, team, proof, purpose)
  })

  /**
   * RPC from UserDO only (S4): `user` revoked `install`. Every unexpired team SSH certificate of
   * that install (and only that user's) goes into the KRL, and the install gets no new one.
   */
  async revokeInstallCerts(entity: string, user: string, install: string): Promise<{ ok: boolean; revoked: Array<number> }> {
    const engine = this.bind(entity)
    return revokeInstallCerts(
      {
        state: () => this.boundEngine?.currentState ?? engine.currentState,
        rows: engine.rows,
        team: entity,
        stream: engine.stream,
        kek: this.env.INTEGRATIONS_KEK,
        sql: this.ctx.storage.sql,
        now: () => Date.now(),
        submitSystem: (op, params, key) => this.submitSystem(op, params, key),
        running: this.sshRunning
      },
      user,
      install
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

  /**
   * Sign-in rules of this team for one user (enterprise P17-4): whether a Stack session needs this
   * team's SSO (sso.enforce with mode enforced, while an active connection serves a verified domain;
   * owners exempt unless sso.enforceForOwners), the minimum client version, and the agent classes
   * grants may be minted for. `user` need not be a member: the Worker also asks the team that owns
   * the user's email `domain` (policy-gate.ts), which binds only while a connection serves that
   * domain. Read by the Worker, cached briefly.
   */
  async signInRules(entity: string, user: string, domain?: string): Promise<SignInRules> {
    const state = this.bind(entity).currentState
    const policy = currentPolicy(state).values as PolicyValues
    const values = policy as Record<string, { value: unknown } | undefined>
    const role = roleOf(state, this.rows, user)
    // Bound by its email domain: only while an active connection serves that very domain, or its user could never sign in.
    const servable = domain === undefined ? ssoServable(state) : connectionForDomain(state, domain) !== undefined
    const enforce = enforcedOn(policy, "sso.enforce") && servable
    const owners = enforcedOn(policy, "sso.enforceForOwners")
    const min = values["updates.minimumVersion"]?.value
    const classes = values["agents.allowedClasses"]?.value
    return {
      sso_required: enforce && (role !== "owner" || owners),
      minimum_version: typeof min === "string" ? min : null,
      allowed_classes: Array.isArray(classes) ? (classes as Array<string>) : ["mux", "agent", "run"]
    }
  }

  /** Whether this team's SSO created the Stack session `refreshTokenId` for `stackUser` (sso.enforce, P17-4). */
  async ssoSession(entity: string, refreshTokenId: string, stackUser: string): Promise<boolean> {
    const state = this.bind(entity).currentState
    const connection = ssoSessionConnection(this.ctx.storage.sql, refreshTokenId, stackUser, Date.now(), ssoMaxAgeMs(state))
    // A disabled or deleted connection ends its sessions' standing.
    return connection !== undefined && state.sso_connections?.[connection]?.state === "active"
  }

  /** May this signed-in principal add a server to this team? An early refusal before the approval writes anything. */
  async canEnrollServer(entity: string, principal: Principal): Promise<boolean> {
    const engine = this.bind(entity)
    return principal.kind === "session" && !principal.agent && Boolean(principal.user) && mayEnrollServer(engine.currentState, principal.user, engine.rows)
  }

  /**
   * RPC from the Worker's `server.pair.approve` route (plans/cmux-next/server.md 6.2),
   * after UserDO registered the server's install. `server.enrolled` checks the
   * approver's role in the same commit as the host; when the role is gone it
   * commits a refusal and the install's revocation instead, which this call
   * pushes to UserDO at once (the alarm retries). Keyed by the pairing code, so
   * a retried approval replays the same host or the same refusal.
   */
  async enrollServer(
    entity: string,
    principal: Principal,
    params: { install: string; name: string; platform: string; wg_public_key: string },
    idempotencyKey: string
  ): Promise<{ ok: true; host: string } | { ok: false; code: string; message: string; refused?: true }> {
    this.bind(entity)
    if (principal.kind !== "session" || principal.agent || !principal.user) return { ok: false, code: "auth.forbidden", message: "only a signed-in user may approve a server" }
    const res = this.submitSystem("server.enrolled", { ...params, owner_user: principal.user, approved_by: principal.user }, idempotencyKey)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return { ok: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable", message: reply && reply.t === "reject" ? reply.message : "no reply" }
    const value = reply.value as { id: string } | ServerEnrollRefused
    if ("refused" in value) {
      // Push this install's revocation now unless pushes are backing off; the alarm retries the rest.
      if (this.revokeRetryAt === null || Date.now() >= this.revokeRetryAt) await this.flushServerRevocations(entity, value.install)
      return { ok: false, code: "auth.forbidden", message: value.message, refused: true }
    }
    return { ok: true, host: value.id }
  }

  /** The owner's UserDO for revocation pushes; tests replace it to fail the RPC. */
  userOwner = (user: string): { revokeByTeam(entity: string, team: string, install: string, by: string, idempotencyKey: string): Promise<unknown> } =>
    this.env.USER_DO.get(this.env.USER_DO.idFromName(user))

  /** Backoff after a failed revocation push (in memory: a restart retries at once). */
  private revokeRetryAt: number | null = null
  private revokeAttempts = 0

  /**
   * Pushes every pending server install revocation to its owner's UserDO
   * (`install.revoke_by_team`, which also closes the install's sockets), then
   * records the confirmation. Called by the Worker right after `server.revoke`
   * and by the alarm until it succeeds (`only`: one install, after a refused
   * enrollment). Returns the installs revoked now.
   */
  async flushServerRevocations(entity: string, only?: string): Promise<{ revoked: Array<string> }> {
    if (!entity) return { revoked: [] }
    const engine = this.bind(entity)
    const pending = Object.values(engine.currentState.server_revocations ?? {}).filter((r) => only === undefined || r.install === only)
    const revoked: Array<string> = []
    for (const r of pending) {
      const user = this.userOwner(r.owner_user)
      let res: { ok: boolean; code?: string }
      try {
        res = (await user.revokeByTeam(r.owner_user, entity, r.install, r.by, `team-revoke:${entity}:${r.install}`)) as { ok: boolean; code?: string }
      } catch (e) {
        // A thrown RPC keeps the item in the retried set and never stops the rest of onWake.
        res = { ok: false, code: `rpc:${String(e)}` }
      }
      // Done or permanently impossible (not bound, unknown): stop retrying either way; failures are logged.
      if (!res.ok && res.code !== "auth.forbidden" && res.code !== "selector.not_found") {
        this.revokeAttempts += 1
        this.revokeRetryAt = Date.now() + Math.min(5 * 60_000, 1000 * 2 ** this.revokeAttempts)
        console.error(JSON.stringify({ msg: "server install revocation failed", install: r.install, code: res.code }))
        continue
      }
      if (!res.ok) console.error(JSON.stringify({ msg: "server install revocation refused", install: r.install, code: res.code }))
      this.requireCommitted(this.submitSystem("server.install_revoked", { install: r.install }, `server-install-revoked:${r.install}`))
      if (res.ok) revoked.push(r.install)
    }
    if (Object.keys(this.boundEngine?.currentState.server_revocations ?? {}).length === 0) {
      this.revokeAttempts = 0
      this.revokeRetryAt = null
    }
    return { revoked }
  }

  /** Stack server access for SSO sign-in; tests replace it. */
  stack: StackServer | undefined = undefined

  private loginDeps(entity: string): LoginDeps {
    const engine = this.bind(entity)
    return {
      state: engine.currentState,
      team: entity,
      sql: this.ctx.storage.sql,
      http: this.http,
      kek: this.env.INTEGRATIONS_KEK,
      stack: this.stack ?? stackServer(this.env),
      now: Date.now(),
      submitSystem: (op, params, key) => this.submitSystem(op, params, key)
    }
  }

  /** RPCs from the unauthenticated SSO routes (sso-routes.ts). */
  async ssoStart(entity: string, email: string, callbackBase: string, returnTo: string, clientChallenge: string) {
    return ssoStart(this.loginDeps(entity), email, callbackBase, returnTo, clientChallenge)
  }

  async ssoCallback(entity: string, state: string, code: string, pathConnection: string, iss: string | null) {
    return ssoCallback(this.loginDeps(entity), state, code, pathConnection, iss)
  }

  async ssoRedeem(entity: string, code: string, clientVerifier: string) {
    this.bind(entity)
    return ssoRedeem(this.ctx.storage.sql, this.env.INTEGRATIONS_KEK, entity, code, clientVerifier, Date.now())
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return memberOf(state, this.rows, principal.user) !== undefined
  }
}
