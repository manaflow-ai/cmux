import type { Domain, EventFrame, OpFrame, OwnerEngine, OwnerFrame, Principal } from "@cmux/ownership"
import { conversation as homeConversation, inbox as homeInbox } from "@cmux/home-core"
import { challengeMessagePrefix, type PushTarget } from "@cmux/protocol"
import { emailDomainOf, verifyInstallSignature, type InstallClaims } from "./auth.ts"
import { verifyAttestation, type AttestedKey } from "./app-attest.ts"
import { admit } from "./domains/common.ts"
import { grantFor, installActive, jwkThumbprint, makeUserDomain, type UserState } from "./domains/user.ts"
import { appIdHashFor, confirmView } from "./domains/user-confirm.ts"
import { chiefList } from "./domains/user-chief.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type Attachment, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { SecondaryStream } from "./secondary-stream.ts"

/** Inbox entries a list scans at most (p99 2,000 conversations per user, design section 6). */
const INBOX_SCAN_LIMIT = 10_000

const CHALLENGE_TTL_MS = 2 * 60_000

export type RedeemResult = ({ ok: true } & InstallClaims) | { ok: false; code: "auth.forbidden" | "validation.invalid"; message: string }

/**
 * UserDO: the user's installs, devices, grants and revocation (identity spec
 * section 2). Also verifies install proof of possession for token mint; the
 * one-time challenges live outside the op protocol because they are
 * credentials, not shared entity state.
 */
/** POST /v1/presence-key body. */
export interface PresenceKeyBody {
  readonly platform?: unknown
  readonly jwk?: unknown
  readonly signature?: unknown
  readonly attestation?: unknown
  readonly key_id?: unknown
}

export class UserDO extends OwnerDO<UserState> {
  /** UserDO is the revocation authority: it closes a revoked install's sockets itself (afterOp). */
  protected override checksInstallRevocation = false
  /** Second stream `inbox:<user>` (lane 15 E2): Home inbox entries, pins, mutes, archive. */
  private readonly inbox: SecondaryStream<homeInbox.InboxHead>

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, makeUserDomain(appIdHashFor(env.IOS_APP_ID)), "user")
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS auth_challenges (nonce TEXT PRIMARY KEY, install TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    this.inbox = new SecondaryStream(ctx, this.sqlStore, {
      prefix: "inbox",
      tablePrefix: "inbox_",
      // Params arrive as untrusted JSON; the inbox reducer validates them (validBump, userOp).
      domain: homeInbox.inboxDomain as Domain<homeInbox.InboxHead>,
      // Entries are unordered rows (n = null): snapshots carry the head; clients page with inbox.list.
      engine: { rowMode: { snapshotTable: homeInbox.TABLE_ENTRY, snapshotTail: 0 } },
      owns: (op) => op.startsWith("inbox."),
      maySubscribe: (_head, principal, entity) => principal.user === entity
    }, (ws, a) => this.socketLive(ws, a))
  }

  /** The inbox engine of the bound user, opened on first use (also after hibernation). */
  private boundInbox() {
    const engine = this.existing()
    return engine ? this.inbox.open(engine.stream.slice("user:".length)) : undefined
  }

  protected override routeFrame(ws: WebSocket, a: Attachment, frame: { readonly t?: string; readonly stream?: unknown; readonly op?: unknown } & Record<string, unknown>): boolean {
    // Ops the Worker gates on team policy (agents.allowedClasses, P17-4) never run from the socket.
    if (frame.t === "op" && frame.op === "chief.create") {
      try {
        ws.send(JSON.stringify({ t: "reject", tx: "", idempotency_key: frame.idempotency_key ?? "", code: "validation.invalid", message: "chief.create goes through POST /v1/ops", retryable: false, replayed: false }))
      } catch {}
      return true
    }
    if (!this.inbox.handles(frame)) return false
    const engine = this.existing()
    if (!engine) return false
    this.inbox.onFrame(ws, a, engine.stream.slice("user:".length), frame)
    this.scheduleAlarm()
    return true
  }

  protected override systemEngine(op: string, entity: string) {
    if (!op.startsWith("inbox.")) return super.systemEngine(op, entity)
    return { engine: this.inbox.open(entity) as OwnerEngine<unknown>, publish: (f: OwnerFrame) => this.inbox.publish(f) }
  }

  protected override nextWakeAt(): number | null {
    this.boundInbox()
    const inbox = this.inbox.nextWakeAt()
    const pending = Object.keys(this.boundEngine?.currentState.ssh_revoke_pending ?? {}).length > 0 ? Math.max(Date.now(), this.sshRetryAt ?? 0) : null
    return inbox === null ? pending : pending === null ? inbox : Math.min(inbox, pending)
  }

  /** Backoff after a failed KRL notice (in memory: a restart retries at once). */
  private sshRetryAt: number | null = null
  private sshAttempts = 0

  /**
   * Delivers pending KRL notices for revoked installs to each team's TeamDO and clears each one
   * when every team confirmed (S4). TeamDO's side is idempotent, so a retry after a crash is safe.
   */
  protected override async onWake(now: number): Promise<void> {
    const engine = this.existing()
    const pending = Object.entries(engine?.currentState.ssh_revoke_pending ?? {})
    if (pending.length === 0 || (this.sshRetryAt !== null && now < this.sshRetryAt)) return
    // Every install and team is tried on each pass: one failing team never holds back the others.
    let failed = false
    for (const [install, n] of pending) {
      let all = true
      for (const team of n.teams) {
        try {
          const r = (await this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team)).revokeInstallCerts(team, n.user, install)) as { ok: boolean }
          if (!r.ok) throw new Error("refused")
        } catch (e) {
          all = false
          console.error(JSON.stringify({ msg: "team ssh krl notice failed", install, team, attempt: this.sshAttempts + 1, error: String(e) }))
        }
      }
      if (all) this.submitSystem("install.ssh_revoke_done", { install }, `ssh-revoke-done:${install}:${n.at}`)
      else failed = true
    }
    if (failed) {
      this.sshAttempts += 1
      this.sshRetryAt = now + Math.min(5 * 60_000, 1000 * 2 ** this.sshAttempts)
    } else {
      this.sshAttempts = 0
      this.sshRetryAt = null
    }
  }

  protected override onPrune(): void {
    this.boundInbox()
    this.inbox.prune(Date.now())
  }

  /** RPC: an inbox op (pin, mute, archive, mark unread) from the user's session or install. */
  async submitInbox(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    const refused = this.inboxRefusal(entity, principal, frame.op)
    if (refused) return { frames: [{ t: "reject", tx: "", idempotency_key: frame.idempotency_key, code: refused.code, message: refused.message, retryable: false, replayed: false } as OwnerFrame] }
    this.inbox.open(entity)
    const frames: Array<OwnerFrame> = []
    this.inbox.submit(principal, frame, (f) => frames.push(f))
    this.scheduleAlarm()
    return { frames }
  }

  /** RPC: inbox reads. `inbox.list` pages the entries; `inbox.dm_peer` finds an existing DM with a peer (design Q2). */
  async readInbox(entity: string, principal: Principal, op: string, params: Record<string, unknown>): Promise<ReadResult> {
    const refused = this.inboxRefusal(entity, principal, op)
    if (refused) return { ok: false, code: refused.code, message: refused.message }
    const engine = this.inbox.open(entity)
    if (op === "inbox.dm_peer") {
      const peer = typeof params.peer === "string" ? params.peer : ""
      return { ok: true, value: { conversation: homeInbox.dmPeer(engine.rows, peer) }, revision: String(engine.currentSeq) }
    }
    if (op === "inbox.list") {
      const entries = engine.rows.scan<homeInbox.InboxEntry>(homeInbox.TABLE_ENTRY, INBOX_SCAN_LIMIT).map((r) => r.row)
      const limit = typeof params.limit === "number" && params.limit > 0 ? Math.min(params.limit, 200) : 200
      const query: homeInbox.InboxListQuery = { limit, include_archived: params.include_archived === true }
      return { ok: true, value: { entries: homeInbox.listInbox(entries, query) }, revision: String(engine.currentSeq) }
    }
    return { ok: false, code: "validation.invalid", message: `unknown inbox read ${op}` }
  }

  /**
   * POST /v1/presence-key (home-messaging.md section 21): an owner device registers the
   * Secure Enclave key that later signs level lowering. The caller is the install itself.
   * Both platforms: the install key signs `cmux-presence-key-v1\n<environment>\n<user>\n<install>\n<thumbprint>`.
   * iOS also sends an App Attest attestation whose client data is the presence key's thumbprint,
   * verified against Apple's root for this deployment's IOS_APP_ID. Then the system op
   * `user.presence_key.register` commits (usable after 24 h; every device and the email are told).
   */
  async registerPresenceKey(entity: string, principal: Principal, body: PresenceKeyBody): Promise<SubmitResult | { error: { code: string; message: string } }> {
    const refuse = (code: string, message: string) => ({ error: { code, message } })
    if (principal.kind !== "install" || principal.agent || principal.user !== entity || !principal.install) return refuse("auth.forbidden", "an owner device install registers its own key")
    const state = this.bind(entity).currentState
    const inst = state.installs[principal.install]
    if (!installActive(state, principal) || !inst) return refuse("auth.forbidden", "install revoked or unknown")
    if ((body.platform !== "mac" && body.platform !== "ios") || inst.kind !== body.platform) return refuse("validation.invalid", "platform must be this install's kind (mac or ios)")
    const jwk = body.jwk as { kty?: string; crv?: string; x?: string; y?: string } | undefined
    if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.x !== "string" || typeof jwk.y !== "string") return refuse("validation.invalid", "jwk must be a P-256 public key")
    const thumbprint = jwkThumbprint({ kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y })
    let appAttest: AttestedKey | undefined
    // Both platforms: the install key signs the registration, so a stolen bearer token alone cannot replace the key.
    const message = `cmux-presence-key-v1\n${this.env.ENVIRONMENT}\n${entity}\n${inst.id}\n${thumbprint}`
    if (typeof body.signature !== "string" || !(await verifyInstallSignature(inst.public_jwk, message, body.signature))) return refuse("auth.forbidden", "the install key did not sign this registration")
    if (body.platform === "ios") {
      if (!this.env.IOS_APP_ID) return refuse("presence_key.not_configured", "App Attest is not configured on this deployment")
      if (typeof body.attestation !== "string" || typeof body.key_id !== "string") return refuse("validation.invalid", "attestation and key_id are required on iOS")
      const r = verifyAttestation({
        attestation: body.attestation,
        keyId: body.key_id,
        clientData: new TextEncoder().encode(thumbprint),
        appId: this.env.IOS_APP_ID,
        allowDevelopment: this.env.IOS_APP_ATTEST_DEVELOPMENT === "true",
        now: Date.now()
      })
      if (!r.ok) return refuse("auth.forbidden", `attestation refused (${r.reason})`)
      appAttest = r.key
    }
    const params = { install: inst.id, jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, platform: body.platform, ...(appAttest ? { app_attest: appAttest } : {}) }
    return this.submitSystem("user.presence_key.register", params, `presence-key:${inst.id}:${thumbprint}`, `system:user:${entity}`)
  }

  /**
   * RPC from TeamDO only (team-vm-plan.md 3c, decision SSH-1): a presence challenge on one of
   * this user's devices, bound to one full-shell SSH certificate request of `team`. The challenge
   * lives in the text confirmation state (same keys, nonces and cooldown as a lowering).
   */
  async presenceChallenge(
    entity: string,
    team: string,
    install: string,
    purpose: unknown
  ): Promise<{ ok: true; value: { sign: unknown; message: string; expires_at: number } } | { ok: false; code: string; message: string }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { ok: false, code: "selector.not_found", message: "unknown user" }
    const res = this.submitSystem("user.presence.challenge", { install, purpose }, `presence-challenge:${crypto.randomUUID()}`, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return { ok: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable", message: reply && reply.t === "reject" ? reply.message : "no reply" }
    return { ok: true, value: reply.value as { sign: unknown; message: string; expires_at: number } }
  }

  /**
   * RPC from TeamDO only: checks the signed proof for that request and spends its nonce. The
   * ledger key is the nonce, so a TeamDO retry after a crash gets the same answer, and the same
   * nonce with another request is an idempotency conflict (never a second approval).
   */
  async presenceAssert(
    entity: string,
    team: string,
    proof: { install: string; nonce: string; signature: string; app_attest?: string },
    purpose: unknown
  ): Promise<{ asserted: boolean; code?: string; expires_at?: number }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { asserted: false, code: "selector.not_found" }
    const params = { install: proof.install, nonce: proof.nonce, purpose, presence_sig: proof.signature, ...(proof.app_attest ? { app_attest: proof.app_attest } : {}) }
    const res = this.submitSystem("user.presence.assert", params, `presence-assert:${proof.nonce}`, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t !== "result") return { asserted: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable" }
    return reply.value as { asserted: boolean; code?: string; expires_at?: number }
  }

  /**
   * Inbox calls come from this user only, through an active install whose grant covers the op
   * (the catalog check other owners apply), checked before the object binds the entity.
   */
  private inboxRefusal(entity: string, principal: Principal, op: string): { code: string; message: string } | undefined {
    if (principal.user !== entity) return { code: "auth.forbidden", message: "not this user's inbox" }
    const state = this.bind(entity).currentState
    if (!installActive(state, principal)) return { code: "auth.forbidden", message: "install revoked or unknown" }
    return admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
  }

  protected read(state: UserState, op: string, params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user.id) return { ok: false, code: "auth.forbidden", message: "not this user" }
    // A revoked install's still-valid token reads nothing (it would otherwise read until the token expires).
    if (!installActive(state, principal)) return { ok: false, code: "auth.forbidden", message: "install revoked or unknown" }
    if (op === "chief.list") {
      const refused = admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
      return refused ? { ok: false, ...refused } : { ok: true, value: chiefList(state, Date.now(), (params as { include_archived?: unknown } | null)?.include_archived === true), revision: "" }
    }
    if (op === "user.text_confirm.get") {
      const refused = admit("cloud:UserDO", op, principal, (p) => grantFor(state, p), Date.now())
      return refused ? { ok: false, ...refused } : { ok: true, value: confirmView(state), revision: "" }
    }
    if (op !== "install.list") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { user: state.user, installs: Object.values(state.installs), grants: Object.values(state.grants) }, revision: "" }
  }

  /** Device push tokens reach only the user's session and the install that owns each token. */
  protected override subscriberView(state: UserState, principal: Principal): unknown {
    if (principal.kind === "session" || !state.push_targets) return state
    const own = Object.fromEntries(Object.entries(state.push_targets).filter(([, t]) => t.install === principal.install))
    return { ...state, push_targets: own }
  }

  /** Push-target events carry a device token: only the session and the install that owns it receive them. */
  protected override mayReceive(_state: UserState, event: EventFrame, principal: Principal): boolean {
    if (!event.op.startsWith("push.target.")) return true
    return principal.kind === "session" || (principal.install !== undefined && event.actor.install === principal.install)
  }

  protected maySubscribe(state: UserState, principal: Principal): boolean {
    return (!state.user || state.user.id === principal.user) && installActive(state, principal)
  }

  /** RPC from other owners (OwnerDO.runInstallChecks): which of these installs (with the token's grant) are active. Never creates an object. */
  async installsActive(entity: string, list: ReadonlyArray<{ install: string; grant: string | undefined }>): Promise<ReadonlyArray<boolean>> {
    // One answer per entry, in order (two sockets of one install may hold different grants).
    if (!this.isBound(entity)) return list.map(() => false)
    const state = this.bind(entity).currentState
    return list.map((x) => installActive(state, { identity: x.install, kind: "install", user: entity, install: x.install, ...(x.grant ? { grant: x.grant } : {}) }))
  }

  /** A revoked install loses its open sockets at once, not at token expiry. */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>) {
    if (op !== "install.revoke" && op !== "install.revoke_by_team") return
    const result = frames.find((f) => f.t === "result")
    const revoked = result && result.t === "result" ? (result.value as { id?: string }).id : undefined
    if (revoked) this.closeSockets((p) => p.install === revoked, "install revoked")
  }

  /**
   * RPC from TeamDO only (plans/cmux-next/server.md 6.5): the team revoked a
   * server whose install is bound to it. Revokes the grant and closes the
   * install's sockets in the same commit; refuses an install not bound to `team`.
   */
  async revokeByTeam(entity: string, team: string, install: string, by: string, idempotencyKey: string): Promise<{ ok: true } | { ok: false; code: string; message: string }> {
    const engine = this.existing()
    if (!engine || engine.currentState.user?.id !== entity) return { ok: false, code: "selector.not_found", message: "unknown user" }
    const res = this.submitSystem("install.revoke_by_team", { install, team, by }, idempotencyKey, `system:team:${team}`)
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    return reply && reply.t === "result" ? { ok: true } : { ok: false, code: reply && reply.t === "reject" ? reply.code : "owner.unreachable", message: reply && reply.t === "reject" ? reply.message : "no reply" }
  }

  /**
   * Home attachment quota (home-scale.md B9 owner counters): per rolling 24 h, 300 intents and
   * 2 GB of declared bytes (`key` = conversation and hash, so a repeat adds no bytes), and 10 GB
   * stored (objects this user uploaded first that still exist).
   */
  async takeAttachmentQuota(entity: string, key: string, bytes: number): Promise<homeConversation.QuotaResult | { ok: false; code: "auth.forbidden"; window: "none"; retry_after_ms: 0 }> {
    if (!this.attachmentTables(entity)) return { ok: false, code: "auth.forbidden", window: "none", retry_after_ms: 0 }
    const sql = this.ctx.storage.sql
    const now = Date.now()
    const since = now - homeConversation.ATTACHMENT_LIMITS.quota.dayMs
    sql.exec(`DELETE FROM home_attachment_usage WHERE at <= ?`, since)
    sql.exec(`DELETE FROM home_attachment_intents WHERE at <= ?`, since)
    const repeat = sql.exec(`SELECT 1 FROM home_attachment_usage WHERE key = ?`, key).toArray().length > 0
    const usage = {
      bytes: sql.exec<{ bytes: number; at: number }>(`SELECT bytes, at FROM home_attachment_usage`).toArray().map((r) => ({ bytes: Number(r.bytes), at: Number(r.at) })),
      intents: sql.exec<{ at: number }>(`SELECT at FROM home_attachment_intents`).toArray().map((r) => Number(r.at)),
      stored: this.storedBytes()
    }
    const decision = homeConversation.attachmentQuota(usage, { bytes, repeat }, now)
    if (decision.ok) {
      sql.exec(`INSERT INTO home_attachment_intents (at) VALUES (?)`, now)
      if (!repeat) sql.exec(`INSERT INTO home_attachment_usage (key, bytes, at) VALUES (?, ?, ?)`, key, bytes, now)
    }
    return decision
  }

  /** An object this user uploaded first now exists (counts toward the 10 GB stored cap). Idempotent by key. */
  async recordAttachmentStorage(entity: string, objectKey: string, bytes: number): Promise<void> {
    if (!this.attachmentTables(entity)) return
    this.ctx.storage.sql.exec(`INSERT INTO home_attachment_stored (object_key, bytes) VALUES (?, ?) ON CONFLICT (object_key) DO NOTHING`, objectKey, bytes)
  }

  /** The object was collected or its conversation deleted. Idempotent by key. */
  async releaseAttachmentStorage(entity: string, objectKey: string): Promise<void> {
    if (!this.attachmentTables(entity)) return
    this.ctx.storage.sql.exec(`DELETE FROM home_attachment_stored WHERE object_key = ?`, objectKey)
  }

  private storedBytes(): number {
    return Number(this.ctx.storage.sql.exec<{ b: number }>(`SELECT COALESCE(SUM(bytes), 0) AS b FROM home_attachment_stored`).toArray()[0]?.b ?? 0)
  }

  /** Attachment counter tables of a bound user; false (no write) for an id this object never served. */
  private attachmentTables(entity: string): boolean {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return false
    const sql = this.ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_usage (key TEXT PRIMARY KEY, bytes INTEGER NOT NULL, at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_intents (at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_stored (object_key TEXT PRIMARY KEY, bytes INTEGER NOT NULL)`)
    return true
  }

  /** Bound user state, or undefined for an id this object never served (no storage is created). */
  private existing() {
    const row = this.boundRow()
    return row ? this.bind(row.entity) : undefined
  }

  /** For FeedDO: the user's push targets whose install is still active (feed.md 7.3). */
  async pushTargets(entity: string): Promise<ReadonlyArray<PushTarget>> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return []
    const state = engine.currentState
    return Object.values(state.push_targets ?? {}).filter((t) => state.installs[t.install]?.revoked_at === null)
  }

  /** For FeedDO: APNs rejected this token (unregistered or bad); the owner drops it in its own op. */
  async dropPushTarget(entity: string, token: string, reason: string): Promise<void> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return
    this.submitSystem("push.target.drop", { token, reason }, `drop:${token}:${engine.currentSeq}`)
  }

  /** For other owners (TeamDO): is this install active, and what does its grant allow? */
  async installGrant(entity: string, install: string, grant: string): Promise<{ ok: true; op_classes: ReadonlyArray<string>; kind: string; email: string | null; email_verified: boolean } | { ok: false }> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false }
    const state = engine.currentState
    const inst = state.installs[install]
    const g = state.grants[grant]
    if (!inst || inst.revoked_at !== null || inst.grant !== grant || !g || g.revoked_at !== null || (g.expires_at !== null && g.expires_at <= Date.now())) return { ok: false }
    // The email from the user's last Stack session, so other owners can check email-domain rules for installs.
    return { ok: true, op_classes: g.op_classes, kind: inst.kind, email: state.user?.email ?? null, email_verified: state.user?.email_verified === true }
  }

  async challenge(entity: string, install: string): Promise<{ ok: true; nonce: string; expires_at: number } | { ok: false; message: string }> {
    const engine = this.existing()
    // One answer for every refusal, so the endpoint does not reveal which users or installs exist.
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, message: "challenge refused" }
    const inst = engine.currentState.installs[install]
    if (!inst || inst.revoked_at !== null) return { ok: false, message: "challenge refused" }
    const now = Date.now()
    const nonce = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "")
    const sql = this.ctx.storage.sql
    sql.exec(`DELETE FROM auth_challenges WHERE expires_at < ?`, now)
    sql.exec(`INSERT INTO auth_challenges (nonce, install, expires_at) VALUES (?, ?, ?)`, nonce, install, now + CHALLENGE_TTL_MS)
    return { ok: true, nonce, expires_at: now + CHALLENGE_TTL_MS }
  }

  /** One-time challenge + ES256 signature by the install key + revocation check. */
  async redeem(entity: string, install: string, nonce: string, signature: string): Promise<RedeemResult> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
    const sql = this.ctx.storage.sql
    const row = sql.exec<{ install: string; expires_at: number }>(`SELECT install, expires_at FROM auth_challenges WHERE nonce = ?`, nonce).toArray()[0]
    // Consume first: a nonce is single use even when the signature fails.
    sql.exec(`DELETE FROM auth_challenges WHERE nonce = ?`, nonce)
    if (!row || row.install !== install || row.expires_at < Date.now()) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
    const state = engine.currentState
    const inst = state.installs[install]
    if (!inst || inst.revoked_at !== null || !state.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    const grant = state.grants[inst.grant]
    if (!grant || grant.revoked_at !== null) return { ok: false, code: "auth.forbidden", message: "grant revoked" }
    const ok = await verifyInstallSignature(inst.public_jwk, `${challengeMessagePrefix(this.env.ENVIRONMENT, install)}${nonce}`, signature)
    if (!ok) return { ok: false, code: "auth.forbidden", message: "bad signature" }
    // Re-read after the await: a revoke may have committed during the verify.
    const now = engine.currentState
    const stillActive = now.installs[install]?.revoked_at === null && now.grants[grant.id]?.revoked_at === null
    if (!stillActive || !now.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    const emailDomain = emailDomainOf(now.user.email)
    return { ok: true, user: now.user.id, team: now.user.personal_team, install, grant: grant.id, ...(inst.sso_team ? { sso_team: inst.sso_team } : {}), ...(emailDomain ? { email_domain: emailDomain } : {}) }
  }
}
