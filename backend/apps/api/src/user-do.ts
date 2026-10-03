import type { Domain, EventFrame, OpFrame, OwnerEngine, OwnerFrame, Principal } from "@cmux/ownership"
import { inbox as homeInbox } from "@cmux/home-core"
import { challengeMessagePrefix, type PushTarget } from "@cmux/protocol"
import { verifyInstallSignature, type InstallClaims } from "./auth.ts"
import { installActive, userDomain, type UserState } from "./domains/user.ts"
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
export class UserDO extends OwnerDO<UserState> {
  /** Second stream `inbox:<user>` (lane 15 E2): Home inbox entries, pins, mutes, archive. */
  private readonly inbox: SecondaryStream<homeInbox.InboxHead>

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, userDomain, "user")
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
    })
  }

  /** The inbox engine of the bound user, opened on first use (also after hibernation). */
  private boundInbox() {
    const engine = this.existing()
    return engine ? this.inbox.open(engine.stream.slice("user:".length)) : undefined
  }

  protected override routeFrame(ws: WebSocket, a: Attachment, frame: { readonly t?: string; readonly stream?: unknown; readonly op?: unknown } & Record<string, unknown>): boolean {
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
    return this.inbox.nextWakeAt()
  }

  protected override onPrune(): void {
    this.boundInbox()
    this.inbox.prune(Date.now())
  }

  /** RPC: an inbox op (pin, mute, archive, mark unread) from the user's session or install. */
  async submitInbox(entity: string, principal: Principal, frame: OpFrame): Promise<SubmitResult> {
    this.bind(entity)
    this.inbox.open(entity)
    const frames: Array<OwnerFrame> = []
    this.inbox.submit(principal, frame, (f) => frames.push(f))
    this.scheduleAlarm()
    return { frames }
  }

  /** RPC: inbox reads. `inbox.list` pages the entries; `inbox.dm_peer` finds an existing DM with a peer (design Q2). */
  async readInbox(entity: string, principal: Principal, op: string, params: Record<string, unknown>): Promise<ReadResult> {
    if (principal.user !== entity) return { ok: false, code: "auth.forbidden", message: "not this user's inbox" }
    this.bind(entity)
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

  protected read(state: UserState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user.id) return { ok: false, code: "auth.forbidden", message: "not this user" }
    // A revoked install's still-valid token reads nothing (it would otherwise read until the token expires).
    if (!installActive(state, principal)) return { ok: false, code: "auth.forbidden", message: "install revoked or unknown" }
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

  /** Bound user state, or undefined for an id this object never served (no storage is created). */
  private existing() {
    const row = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
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
    return { ok: true, user: now.user.id, team: now.user.personal_team, install, grant: grant.id }
  }
}
