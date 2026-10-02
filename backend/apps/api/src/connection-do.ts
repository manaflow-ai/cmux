import { createHash } from "node:crypto"
import { canonicalJson, LEDGER_RETENTION_MS, type OwnerFrame, type Principal, type RejectFrame } from "@cmux/ownership"
import { cloudOpByName, PENDING_CONNECTION_TTL_MS, type Connection, type IntegrationProvider } from "@cmux/protocol"
import { connectionsDomain, expiredForgets, githubRepoAllowed, mayUse, pendingExpiries, policyOf, providerAllowed, type ConnectionsState } from "./domains/connections.ts"
import { decodeParams } from "./domains/common.ts"
import type { Env } from "./env.ts"
import { aadFor, open, seal, type SealedSecret } from "./integrations/crypto.ts"
import { ProviderError, providerForOp, providers, type Credential, type Http } from "./integrations/providers.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/** The HTTP shape of one op result (http.ts OpResponse). */
export interface ExternalReply {
  readonly ok: boolean
  readonly op: string
  readonly value?: unknown
  readonly error?: { readonly code: string; readonly message: string; readonly retryable: boolean }
  readonly transaction: string
  readonly idempotency_key: string
  readonly replayed: boolean
  readonly stream: string
  readonly sequence: number
}

export interface ProviderEvent {
  readonly provider: IntegrationProvider
  readonly account: string
  readonly delivery_id: string
  readonly event: string
  readonly payload: unknown
}

/** Synchronous, so the ledger check and insert happen in one turn with no await between. */
const sha256 = (s: string) => createHash("sha256").update(s).digest("base64url")

/**
 * ConnectionDO: one per owner team (spec integrations.md; the spec's
 * per-connection object is per team here, see the decision note in the PR).
 * Owns connection records through the op protocol and, outside entity state,
 * the sealed provider credentials. Ops with external effects (finishing an
 * OAuth flow, provider calls) run here with their own idempotency ledger:
 * a retry with the same key replays the stored reply, and a key whose call
 * was cut off answers `mutation.indeterminate` instead of calling twice.
 */
export class ConnectionDO extends OwnerDO<ConnectionsState> {
  /** Provider HTTP. Tests replace it on the live instance. */
  http: Http = (r) => fetch(r)
  /** One token refresh at a time per connection (rotating refresh tokens are single use). */
  private readonly refreshing = new Map<string, Promise<Credential>>()

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, connectionsDomain, "connections", (p) => ({
      identity: p.kind === "system" ? p.identity : (p.install ?? `user:${p.user}`),
      ...(p.kind ? { kind: p.kind } : {}),
      ...(p.user ? { user: p.user } : {}),
      ...(p.team ? { team: p.team } : {}),
      ...(p.install ? { install: p.install } : {}),
      ...(p.display_name ? { display_name: p.display_name } : {})
    }))
    const sql = ctx.storage.sql
    // Credentials: sealed, never in state, events, snapshots, the ledger, logs or the projection.
    sql.exec(`CREATE TABLE IF NOT EXISTS credentials (connection TEXT PRIMARY KEY, generation INTEGER NOT NULL, sealed TEXT NOT NULL, updated_at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS external_calls (
      identity TEXT NOT NULL, idempotency_key TEXT NOT NULL, op TEXT NOT NULL, params_hash TEXT NOT NULL,
      status TEXT NOT NULL, reply TEXT, created_at INTEGER NOT NULL, PRIMARY KEY (identity, idempotency_key))`)
    sql.exec(`CREATE INDEX IF NOT EXISTS external_calls_created ON external_calls (created_at)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS refused_system_ops (key TEXT PRIMARY KEY, code TEXT NOT NULL, at INTEGER NOT NULL)`)
  }

  protected read(state: ConnectionsState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (!principal.team || (state.owner !== null && state.owner !== principal.team)) return { ok: false, code: "auth.forbidden", message: "not this team's connections" }
    if (op === "integration.policy.get") return { ok: true, value: policyOf(state), revision: "" }
    if (op !== "integration.list") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const connections = Object.values(state.connections)
      .filter((c) => mayUse(c, principal))
      .sort((a, b) => a.created_at - b.created_at)
    const configured = (Object.keys(providers) as Array<IntegrationProvider>).map((provider) => ({ provider, configured: Boolean(this.env.INTEGRATIONS_KEK) && providers[provider].configured(this.env) }))
    return { ok: true, value: { connections, providers: configured }, revision: "" }
  }

  protected maySubscribe(state: ConnectionsState, principal: Principal): boolean {
    return Boolean(principal.team && (state.owner === null || state.owner === principal.team))
  }

  /** The external-effect ledger keeps the same 7-day replay window as the op ledger. */
  protected override onPrune(before: number): void {
    this.ctx.storage.sql.exec(`DELETE FROM external_calls WHERE created_at < ?`, before)
    // A refused op's target connection is gone or no longer pending by then.
    const ids = new Set(Object.keys(this.boundEngine?.currentState.connections ?? {}))
    for (const r of this.ctx.storage.sql.exec<{ key: string }>(`SELECT key FROM refused_system_ops WHERE at < ?`, before).toArray()) {
      if (!ids.has(r.key.slice(r.key.indexOf(":") + 1))) this.ctx.storage.sql.exec(`DELETE FROM refused_system_ops WHERE key = ?`, r.key)
    }
  }

  /** The earliest of: a pending connection's expiry, an expired one leaving state, the external-call ledger's prune. */
  protected override nextWakeAt(state: ConnectionsState, _now: number): number | null {
    const oldest = this.ctx.storage.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM external_calls`).toArray()[0]?.at
    const times: Array<number> = []
    if (oldest !== null && oldest !== undefined) times.push(Number(oldest) + LEDGER_RETENTION_MS)
    const skip = this.skipped()
    const expiry = pendingExpiries(state).find((p) => !skip.has(`expire:${p.connection}`))
    if (expiry) times.push(expiry.at)
    const forget = expiredForgets(state).find((p) => !skip.has(`forget:${p.connection}`))
    if (forget) times.push(forget.at)
    return times.length === 0 ? null : Math.min(...times)
  }

  /** System ops that were refused: never retried, so a refusal cannot spin the alarm. Logged loudly. */
  private skipped(): Set<string> {
    return new Set(this.ctx.storage.sql.exec<{ key: string }>(`SELECT key FROM refused_system_ops`).toArray().map((r) => r.key))
  }

  private runSystem(op: string, params: unknown, key: string) {
    const res = this.submitSystem(op, params, key)
    const rej = res.frames.find((f): f is RejectFrame => f.t === "reject")
    if (rej) {
      this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO refused_system_ops (key, code, at) VALUES (?, ?, ?)`, key, rej.code, Date.now())
      console.error(JSON.stringify({ msg: "connection system op refused", key, code: rej.code }))
    }
  }

  /** Expires pending connections whose lifetime ended and drops long-expired ones; keys make repeated alarms replays. */
  protected override async onWake(now: number): Promise<void> {
    const engine = this.boundEngine
    if (!engine) return
    const skip = this.skipped()
    for (const p of pendingExpiries(engine.currentState)) {
      if (p.at > now) break
      if (!skip.has(`expire:${p.connection}`)) this.runSystem("connection.expire", { connection: p.connection, at: now }, `expire:${p.connection}`)
    }
    for (const p of expiredForgets(engine.currentState)) {
      if (p.at > now) break
      if (!skip.has(`forget:${p.connection}`)) this.runSystem("connection.forget", { connection: p.connection, at: now }, `forget:${p.connection}`)
    }
  }

  /** Revocation deletes the credential at once and unlinks the account from webhook routing. */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>) {
    if (op !== "integration.revoke") return
    const result = frames.find((f) => f.t === "result")
    const c = result && result.t === "result" ? (result.value as Connection) : undefined
    if (!c || c.status !== "revoked") return
    this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE connection = ?`, c.id)
    if (c.account) void this.index(c.account.key).remove(c.owner, c.id).catch((e) => console.error(JSON.stringify({ msg: "account index remove failed", connection: c.id, error: String(e) })))
  }

  private index(account: string) {
    return this.env.ACCOUNT_INDEX_DO.get(this.env.ACCOUNT_INDEX_DO.idFromName(account))
  }

  private async sealCredential(c: Connection, credential: Credential) {
    const kek = this.env.INTEGRATIONS_KEK
    if (!kek) throw new ProviderError("integration.unavailable", "integrations are not configured (no INTEGRATIONS_KEK)")
    const row = this.ctx.storage.sql.exec<{ generation: number }>(`SELECT generation FROM credentials WHERE connection = ?`, c.id).toArray()[0]
    const generation = (row?.generation ?? 0) + 1
    const sealed = await seal(kek, JSON.stringify(credential), aadFor(c.id, c.owner, c.provider, generation))
    this.ctx.storage.sql.exec(
      `INSERT INTO credentials (connection, generation, sealed, updated_at) VALUES (?, ?, ?, ?)
       ON CONFLICT (connection) DO UPDATE SET generation = excluded.generation, sealed = excluded.sealed, updated_at = excluded.updated_at`,
      c.id,
      generation,
      JSON.stringify(sealed),
      Date.now()
    )
  }

  private async openCredential(c: Connection): Promise<Credential> {
    const kek = this.env.INTEGRATIONS_KEK
    if (!kek) throw new ProviderError("integration.unavailable", "integrations are not configured (no INTEGRATIONS_KEK)")
    const row = this.ctx.storage.sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM credentials WHERE connection = ?`, c.id).toArray()[0]
    if (!row) throw new ProviderError("needs_reauth", "no stored credential")
    return JSON.parse(await open(kek, JSON.parse(row.sealed) as SealedSecret, aadFor(c.id, c.owner, c.provider, Number(row.generation)))) as Credential
  }

  /**
   * An op with an external effect: `integration.complete` or a provider op.
   * The Worker authenticated the principal and, for complete, verified the
   * signed state and that it names this principal.
   */
  /**
   * RPC from TeamDO: the team's TeamPolicy (single writer) replaces and locks
   * this projection (spec/enterprise.md 4.6). Idempotent by key; a newer
   * version always carries the full slice.
   */
  async applyTeamPolicy(team: string, params: { policy: unknown; applied_by: string }, idempotencyKey: string): Promise<{ ok: boolean; message?: string }> {
    this.bind(team)
    const res = this.submitSystem("integration.policy.apply_managed", { source: "team_policy", ...params }, idempotencyKey)
    const rej = res.frames.find((f): f is RejectFrame => f.t === "reject")
    return rej ? { ok: false, message: rej.message } : { ok: true }
  }

  async external(entity: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string; redirect_uri?: string; state?: { conn: string; provider: string } }): Promise<ExternalReply> {
    const engine = this.bind(entity)
    const identity = principal.identity
    const key = frame.idempotency_key
    const tx = engine.txTag(identity, key)
    const base = { op: frame.op, transaction: tx, idempotency_key: key, stream: engine.stream, sequence: 0 }
    const fail = (code: string, message: string, retryable = false, replayed = false): ExternalReply => ({ ...base, ok: false, error: { code, message, retryable }, replayed })

    const denied = connectionsDomain.authorize!(engine.currentState, frame.op, frame.params, principal)
    if (denied) return fail(denied.code, denied.message)
    const def = cloudOpByName.get(frame.op)
    if (!def) return fail("validation.invalid", `unknown op ${frame.op}`)
    const decoded = decodeParams<Record<string, unknown>>(def, frame.params)
    if (!decoded.ok) return fail(decoded.code, decoded.message)
    const params = decoded.value

    // Ledger for external effects: decided keys replay; an interrupted call is indeterminate.
    const sql = this.ctx.storage.sql
    const hash = sha256(canonicalJson({ op: frame.op, params }))
    const prior = sql.exec<{ params_hash: string; status: string; reply: string | null }>(`SELECT params_hash, status, reply FROM external_calls WHERE identity = ? AND idempotency_key = ?`, identity, key).toArray()[0]
    if (prior) {
      if (prior.params_hash !== hash) return fail("idempotency.conflict", "idempotency key reused with different params")
      if (prior.status === "done" && prior.reply) return { ...(JSON.parse(prior.reply) as ExternalReply), replayed: true }
      return fail("mutation.indeterminate", "an earlier attempt with this key was interrupted; check the provider before retrying with a new key", false, true)
    }
    sql.exec(`INSERT INTO external_calls (identity, idempotency_key, op, params_hash, status, reply, created_at) VALUES (?, ?, ?, ?, 'pending', NULL, ?)`, identity, key, frame.op, hash, Date.now())

    let reply: ExternalReply
    try {
      const value = frame.op === "integration.complete" ? await this.complete(principal, params, frame) : await this.callProvider(principal, frame.op, params)
      // Plain JSON only: a provider field that is absent (undefined) must not break the HTTP encoder.
      reply = { ...base, ok: true, value: JSON.parse(JSON.stringify(value ?? null)) as unknown, replayed: false, sequence: engine.currentSeq }
    } catch (e) {
      if (e instanceof ProviderError) reply = fail(e.code === "needs_reauth" ? "integration.unavailable" : e.code, e.message, e.retryable && e.code !== "mutation.indeterminate")
      else {
        console.error(JSON.stringify({ msg: "external op failed", op: frame.op, stream: engine.stream, error: e instanceof Error ? e.name : "unknown" }))
        reply = fail("operation.failed", "the operation failed")
      }
    }
    // Retryable failures (rate limits, provider 5xx) release the key so the same request may run again.
    if (!reply.ok && reply.error?.retryable) sql.exec(`DELETE FROM external_calls WHERE identity = ? AND idempotency_key = ?`, identity, key)
    else sql.exec(`UPDATE external_calls SET status = 'done', reply = ? WHERE identity = ? AND idempotency_key = ?`, JSON.stringify(reply), identity, key)
    return reply
  }

  private async complete(principal: Principal, params: Record<string, unknown>, frame: { redirect_uri?: string; state?: { conn: string; provider: string } }): Promise<Connection> {
    const st = frame.state
    if (!st || !frame.redirect_uri) throw new ProviderError("integration.state_invalid", "missing verified state")
    const c = this.boundEngine!.currentState.connections[st.conn]
    if (!c || c.provider !== st.provider || c.created_by !== principal.user) throw new ProviderError("integration.state_invalid", "this connection attempt is not yours")
    if (c.status === "revoked") throw new ProviderError("integration.state_invalid", "this connection was revoked")
    // Expired, or past its lifetime with the expiry alarm not yet run: refuse before calling the provider.
    if (c.status === "expired" || (c.status === "pending" && Date.now() >= c.created_at + PENDING_CONNECTION_TTL_MS)) {
      throw new ProviderError("integration.state_invalid", "the connection link expired; start again from Connect")
    }
    const impl = providers[c.provider]
    if (!impl.configured(this.env) || !this.env.INTEGRATIONS_KEK) throw new ProviderError("integration.unavailable", `${c.provider} is not configured`)
    const policy = policyOf(this.boundEngine!.currentState)
    if (!providerAllowed(policy, c.provider)) throw new ProviderError("policy.denied", `the team policy does not allow ${c.provider}`)
    const approved = await impl.complete(this.env, this.http, {
      policy: { githubScope: policy.github.scope, requireOrgAdmin: policy.github.require_org_admin },
      ...(typeof params.code === "string" ? { code: params.code } : {}),
      ...(typeof params.installation_id === "string" ? { installation_id: params.installation_id } : {}),
      redirectUri: frame.redirect_uri
    })
    if (c.account && c.account.key !== approved.account.key) throw new ProviderError("integration.state_invalid", "re-authorization must use the same provider account")
    // A disconnect may have committed while we waited on the provider.
    const now = this.boundEngine!.currentState.connections[c.id]?.status
    if (now === "revoked" || now === "expired") throw new ProviderError("integration.state_invalid", `this connection was ${now}`)
    // Route webhooks first (idempotent), then seal, then commit. If the commit is refused (a
    // disconnect landed in between), undo both so no credential or route outlives it.
    await this.index(approved.account.key).add(c.owner, c.id)
    await this.sealCredential(c, approved.credential)
    const res = this.submitSystem("connection.activate", {
        connection: c.id,
        account: approved.account,
        scopes_granted: [...approved.scopes_granted],
        ...(approved.resources ? { resources: { repos: approved.resources.repos === null ? null : [...approved.resources.repos] } } : {})
      }, `activate:${c.id}:${sha256(canonicalJson([approved.account.key, approved.scopes_granted, approved.resources ?? null])).slice(0, 43)}`)
    const rej = res.frames.find((f): f is RejectFrame => f.t === "reject")
    // An exchange that began inside the lifetime and finished after it still activates when the
    // expiry alarm has not run yet: the provider code is already spent, so refusing would only strand it.
    if (rej) {
      this.ctx.storage.sql.exec(`DELETE FROM credentials WHERE connection = ?`, c.id)
      await this.index(approved.account.key).remove(c.owner, c.id).catch(() => undefined)
      throw new ProviderError("integration.state_invalid", rej.message)
    }
    return this.boundEngine!.currentState.connections[c.id]!
  }

  /** The connection's credential, refreshed (and sealed) first when the provider says it expired. */
  private async usableCredential(c: Connection): Promise<Credential> {
    const impl = providers[c.provider]
    if (!impl.refresh) return this.openCredential(c)
    const running = this.refreshing.get(c.id)
    if (running) return running
    const work = (async () => {
      // Read again inside the single flight: an earlier refresh may have sealed a new one.
      const current = await this.openCredential(c)
      const fresh = await impl.refresh!(this.env, this.http, current)
      if (!fresh) return current
      // Seal before any use: losing a rotated refresh token would force a re-login.
      await this.sealCredential(c, fresh)
      return fresh
    })()
    this.refreshing.set(c.id, work)
    try {
      return await work
    } finally {
      this.refreshing.delete(c.id)
    }
  }

  /** A provider read (no effect, no ledger): same authorization, policy and token path as provider ops. */
  async providerRead(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }> {
    const engine = this.bind(entity)
    const denied = connectionsDomain.authorize!(engine.currentState, op, params, principal)
    if (denied) return { ok: false, code: denied.code, message: denied.message }
    const def = cloudOpByName.get(op)
    if (!def) return { ok: false, code: "validation.invalid", message: `unknown op ${op}` }
    const decoded = decodeParams<Record<string, unknown>>(def, params)
    if (!decoded.ok) return { ok: false, code: decoded.code, message: decoded.message }
    try {
      return { ok: true, value: JSON.parse(JSON.stringify((await this.callProvider(principal, op, decoded.value)) ?? null)) as unknown }
    } catch (e) {
      if (e instanceof ProviderError) return { ok: false, code: e.code === "needs_reauth" ? "integration.unavailable" : e.code, message: e.message }
      return { ok: false, code: "operation.failed", message: "the operation failed" }
    }
  }

  private async callProvider(principal: Principal, op: string, params: Record<string, unknown>): Promise<unknown> {
    const provider = providerForOp(op)
    const c = this.boundEngine!.currentState.connections[String(params.connection)]
    if (!provider || !c || !mayUse(c, principal) || c.provider !== provider) throw new ProviderError("provider.error", "connection not found for this provider")
    if (c.status !== "active") throw new ProviderError("integration.unavailable", `connection is ${c.status}`)
    if (!providerAllowed(policyOf(this.boundEngine!.currentState), c.provider)) throw new ProviderError("policy.denied", `the team policy does not allow ${c.provider}`)
    if (provider === "github" && typeof params.repo === "string" && !githubRepoAllowed(c, policyOf(this.boundEngine!.currentState), params.repo)) {
      throw new ProviderError("policy.denied", `this connection may not act on ${params.repo} (team policy or the linking user's access)`)
    }
    const impl = providers[provider]
    if (!impl.configured(this.env)) throw new ProviderError("integration.unavailable", `${provider} is not configured`)
    try {
      const r = await impl.call(this.env, this.http, await this.usableCredential(c), op, params)
      return r.value
    } catch (e) {
      if (e instanceof ProviderError && e.code === "needs_reauth") {
        this.submitSystem("connection.status", { connection: c.id, status: "needs_reauth", detail: e.message.slice(0, 300) }, `status:${c.id}:needs_reauth:${Date.now()}`)
      }
      throw e
    }
  }

  /**
   * A verified provider webhook for one of this team's connections. Inactive
   * connections drop it. Dedupe happens in the SchedulerDO per trigger
   * (`deliver:<automation>:<trigger>:<connection>:<delivery>`), so a failed
   * forward can be redelivered by the provider.
   */
  async ingest(entity: string, connection: string, event: ProviderEvent): Promise<{ status: "forwarded" | "dropped"; runs: number }> {
    const bound = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    if (!bound || bound.entity !== entity) return { status: "dropped", runs: 0 }
    const c = this.bind(entity).currentState.connections[connection]
    if (!c || c.status !== "active" || c.account?.key !== event.account) return { status: "dropped", runs: 0 }
    if (!providerAllowed(policyOf(this.boundEngine!.currentState), c.provider)) return { status: "dropped", runs: 0 }
    // GitHub events from repositories outside the connection's scope never start automations.
    const repo = (event.payload as { repository?: { full_name?: unknown } } | null)?.repository?.full_name
    if (event.provider === "github" && typeof repo === "string" && !githubRepoAllowed(c, policyOf(this.boundEngine!.currentState), repo)) return { status: "dropped", runs: 0 }
    if (event.provider === "github" && event.event === "installation.deleted") {
      this.submitSystem("connection.status", { connection: c.id, status: "needs_reauth", detail: "the GitHub App was uninstalled" }, `status:${c.id}:uninstalled:${event.delivery_id}`)
    }
    const scheduler = this.env.SCHEDULER_DO.get(this.env.SCHEDULER_DO.idFromName(entity))
    const r = (await scheduler.deliverEvent(entity, { connection: c.id, sharing: c.sharing, created_by: c.created_by, ...event })) as { runs: number }
    return { status: "forwarded", runs: r.runs }
  }
}
