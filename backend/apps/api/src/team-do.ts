import { compileNetwork, createFreestyleClient, reconcile, type FreestyleNetworkApi, type NetworkScope, type ReconcileReport } from "@cmux/network-policy"
import type { Principal, RejectFrame } from "@cmux/ownership"
import type { ReconcileRecordParams } from "@cmux/protocol"
import { directoryOf, effectivePolicy, net, networkInUse, readNetwork } from "./domains/network.ts"
import { teamDomain, type TeamState } from "./domains/team.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"

/** Slow server-side drift check (spec "Reconciler": a periodic reconciliation is acceptable server-side). */
const DRIFT_CHECK_MS = 10 * 60_000
const MAX_RETRY_MS = 5 * 60_000

/**
 * Freestyle namespace for this Worker's environment: production uses
 * `cmuxnp-<team tag>`; staging and everything else (development, local,
 * previews, tests) use the `cmuxnp-staging-` / `cmuxnp-dev-` prefixes with an
 * expiry that the hourly cleanup honors (they share the production account).
 */
export const networkEnv = (environment: string): NetworkScope["env"] => (environment === "production" ? null : environment === "staging" ? "staging" : "dev")

const rejected = (r: SubmitResult): RejectFrame | undefined => r.frames.find((f): f is RejectFrame => f.t === "reject")

/** TeamDO: membership cache, the account directory of hosts (U2) and the team network (network-policy.md). */
export class TeamDO extends OwnerDO<TeamState> {
  /** In-memory scheduling hints (not entity state): reconcile retry backoff and the last drift check. */
  private reconcileRetry: { attempts: number; at: number; seq: number } | null = null
  private lastDriftCheck = 0
  /** Test seam: the Freestyle API the reconciler uses. */
  networkApiFactory: (() => FreestyleNetworkApi | null) | null = null

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
    if (!principal.user || !state.members[principal.user]) return { ok: false, code: "auth.forbidden", message: "not a member of this team" }
    if (op.startsWith("network.")) {
      const r = readNetwork(state, op, params, principal)
      return r.ok ? { ok: true, value: r.value, revision: "" } : r
    }
    if (op !== "team.directory") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { team: state.team?.id, members: Object.values(state.members), hosts: Object.values(state.hosts) }, revision: "" }
  }

  protected maySubscribe(state: TeamState, principal: Principal): boolean {
    return Boolean(principal.user && state.members[principal.user])
  }

  private networkApi(): FreestyleNetworkApi | null {
    if (this.networkApiFactory) return this.networkApiFactory()
    if (!this.env.FREESTYLE_API_KEY) return null
    return createFreestyleClient({ apiKey: this.env.FREESTYLE_API_KEY, ...(this.env.FREESTYLE_API_URL ? { baseUrl: this.env.FREESTYLE_API_URL } : {}) })
  }

  protected override nextWakeAt(state: TeamState, now: number): number | null {
    const n = net(state)
    const r = n.reconcile
    if (r.desired_seq > r.applied_seq) {
      // A failed attempt for this desired state waits for its backoff; anything newer goes now.
      return this.reconcileRetry && this.reconcileRetry.seq === r.desired_seq ? this.reconcileRetry.at : now
    }
    if (!networkInUse(n) || !r.last?.configured) return null
    return Math.max(this.lastDriftCheck, r.last.at) + DRIFT_CHECK_MS
  }

  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine?.currentState.team) return
    const state = engine.currentState
    const n = net(state)
    const team = state.team!.id
    const seq = n.reconcile.desired_seq
    const pending = seq > n.reconcile.applied_seq
    if (pending && this.reconcileRetry?.seq === seq && this.reconcileRetry.at > now) return
    const driftDue = !pending && networkInUse(n) && n.reconcile.last?.configured && now >= Math.max(this.lastDriftCheck, n.reconcile.last.at) + DRIFT_CHECK_MS
    if (!pending && !driftDue) return

    // Durable revocation: the UserDO notice is best effort, so every wake also asks UserDO about live devices.
    if (await this.dropRevokedInstalls()) return

    const api = this.networkApi()
    if (!api) {
      // Not configured in this environment: record it once per desired state so the alarm does not spin.
      if (pending) this.record({ desired_seq: seq, started_at: now, ms: 0, converged: false, configured: false, actions: [], drift: [], deferred: 0, vpc_id: null, tunnels: [] })
      return
    }
    const dir = directoryOf(state)
    let report: ReconcileReport
    try {
      report = await reconcile(api, { team, env: networkEnv(this.env.ENVIRONMENT) }, compileNetwork(effectivePolicy(n), dir), dir, { expectConverged: !pending && Boolean(n.reconcile.last?.converged) })
    } catch (e) {
      // Reads failed (Freestyle unreachable): nothing is known to have changed; back off and retry.
      this.backoff(seq, now)
      console.error(JSON.stringify({ msg: "network reconcile failed", team, seq, error: String(e) }))
      if (pending && (this.reconcileRetry?.attempts ?? 0) === 1)
        this.record({ desired_seq: seq, started_at: now, ms: 0, converged: false, configured: true, actions: [], drift: [], deferred: 0, vpc_id: n.reconcile.vpc_id, tunnels: [], error: String(e).slice(0, 500) }, `reconcile:${seq}:error`)
      return
    }
    this.lastDriftCheck = now
    const failed = report.outcomes.some((o) => !o.ok) || !report.converged
    if (failed) this.backoff(seq, now)
    else this.reconcileRetry = null
    // A clean drift check that changed nothing is not recorded: the ledger keeps every key.
    const foreign = report.foreign.map((r) => r.id).sort()
    const foreignChanged = JSON.stringify(foreign) !== JSON.stringify(n.reconcile.last?.foreign ?? [])
    if (!pending && report.outcomes.length === 0 && report.drift.length === 0 && !foreignChanged) return
    if (foreign.length > 0) console.warn(JSON.stringify({ msg: "network: unmanaged Freestyle rules grant access to team resources", team, rules: foreign }))
    this.record({
      desired_seq: seq,
      started_at: report.startedAt,
      ms: report.ms,
      converged: report.converged,
      configured: true,
      actions: report.outcomes.map((o) => ({ op: o.action.op, ok: o.ok, ms: o.ms, ...(o.error ? { error: `${o.error.status} ${o.error.code}` } : {}) })),
      drift: report.drift.map((a) => a.op),
      deferred: report.deferred.length,
      foreign,
      vpc_id: report.vpc?.id ?? null,
      tunnels: report.tunnels.map((t) => ({
        install: t.install,
        client_public_key: t.clientPublicKey,
        tunnel: { tunnel_id: t.tunnelId, client_config: t.clientConfig, endpoint: t.endpoint, address_v4: t.address_v4, address_v6: t.address_v6, server_public_key: t.serverPublicKey, ready_at: report.startedAt + report.ms }
      }))
    })
  }

  private backoff(seq: number, now: number) {
    const attempts = this.reconcileRetry?.seq === seq ? this.reconcileRetry.attempts + 1 : 1
    this.reconcileRetry = { attempts, seq, at: now + Math.min(MAX_RETRY_MS, 1000 * 2 ** attempts) }
  }

  private record(params: typeof ReconcileRecordParams.Type, key = `reconcile:${params.desired_seq}:${params.started_at}`) {
    const r = rejected(this.submitSystem("network.reconcile.record", params, key))
    if (r) {
      // A rejected record leaves the desired state pending; back off instead of reconciling in a hot loop.
      this.backoff(params.desired_seq, Date.now())
      console.error(JSON.stringify({ msg: "network reconcile record rejected", code: r.code, message: r.message }))
    }
  }

  /** Submits network.install.revoked for devices whose install UserDO reports revoked. True when any was dropped (state changed; the next wake reconciles). */
  private async dropRevokedInstalls(): Promise<boolean> {
    const state = this.boundEngine?.currentState
    if (!state) return false
    let dropped = false
    for (const d of Object.values(net(state).devices)) {
      if (d.revoked_at !== null) continue
      try {
        const status = await this.env.USER_DO.get(this.env.USER_DO.idFromName(d.user)).installStatus(d.user, d.install)
        if (status === "revoked") {
          const r = rejected(this.submitSystem("network.install.revoked", { install: d.install }, `install-revoked:${d.install}`))
          if (!r) dropped = true
        }
      } catch (e) {
        console.error(JSON.stringify({ msg: "network install status check failed", install: d.install, error: String(e) }))
      }
    }
    return dropped
  }

  /** RPC from UserDO: an install was revoked; drop its device at once (one key per install). */
  async networkInstallRevoked(entity: string, install: string): Promise<{ ok: boolean }> {
    const row = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!row || row.entity !== entity) return { ok: false }
    this.bind(entity)
    const r = rejected(this.submitSystem("network.install.revoked", { install }, `install-revoked:${install}`))
    return { ok: !r }
  }
}
