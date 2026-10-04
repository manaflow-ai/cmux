import { tablesFor, type Domain, type EventFrame, type OwnerEngine, type OwnerFrame, type Principal } from "@cmux/ownership"
import { conversation, invites } from "@cmux/home-core"

/** An invite still waiting for its recipient (pending, or waiting for approval). */
const isOpen = (i: conversation.Invite) => i.status === "pending" || i.status === "pending_approval"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"
import { withAdmit } from "./home-admit.ts"

type Head = conversation.ConversationState
const MAX_HISTORY_PAGE = 200
/** Ops the Worker completes (home-routes.ts); refused on the conversation socket. */
const WORKER_DERIVED_OPS = new Set(["conversation.create", "dm.open", "invite.create", "invite.accept", "conversation.import", "conversation.import.commit", "participants.add"])

/**
 * Reach policy with owner records: an agent participant is allowed when it is one of the
 * caller's chiefs (principal.owned_agents, resolved by the Worker from UserDO); everything
 * else follows home-core's default policy.
 */
const ownerRecordPolicy: conversation.ParticipantPolicy = (principal, participant, head) => {
  if (participant.kind === "agent") {
    const owned = principal.owned_agents?.find((a) => a.id === participant.id)
    const actor = conversation.actorOf(principal)
    if (owned && actor?.startsWith("user_")) return { ok: true, owner_user: actor, display_name: owned.display_name }
  }
  return conversation.defaultParticipantPolicy(principal, participant, head)
}
/** Accept rejects that count toward the lock (a wrong or used link), not transient ones. */
const ACCEPT_FAILURES = new Set(["unknown_invite", "invite_not_pending", "invite_expired"])

/** First word of a display name, for the public invite card (never a full name or an address). */
const firstName = (name: string | undefined): string | null => {
  const first = (name ?? "").trim().split(/\s+/)[0] ?? ""
  return first.length > 0 && first.length <= 40 && !first.includes("@") ? first : null
}

export type InvitePreviewResult =
  | { readonly state: "ok"; readonly inviter: string; readonly kind: "dm" | "group"; readonly title?: string }
  | { readonly state: "invalid" | "expired" }

/**
 * ConversationDO, one per conversation (home-messaging.md section 3): head, participants,
 * messages, reactions, edits, read cursors and invites, run by lane 15's pure domain in row
 * mode. Token hashes and accept proofs stay here (conversationRedact, private `invhash`).
 */
export class ConversationDO extends OwnerDO<Head> {
  constructor(ctx: DurableObjectState, env: Env) {
    const domain = conversation.makeConversationDomain({
      participantPolicy: ownerRecordPolicy,
      // The caller's verified address ids (HMAC with HOME_ADDRESS_KEY), for binding an email invite on accept.
      addressIdsFor: (p) => {
        if (p.email_verified !== true || !p.email || !env.HOME_ADDRESS_KEY) return []
        const address = invites.normalizeEmail(p.email)
        return invites.isAddress(address) ? [invites.addressId(env.HOME_ADDRESS_KEY, address)] : []
      }
    })
    super(ctx, env, withAdmit("cloud:ConversationDO", domain as Domain<Head>), "conv", publicActor, {
      rowMode: { snapshotTable: conversation.TABLE_MSG, snapshotTail: 50 },
      redact: { ...conversation.conversationRedact, privateTables: conversation.PRIVATE_TABLES },
      // DO audit F-3: 7 days, at most 10,000 events and 256 MB, never fewer than the newest 1,000.
      eventWindow: { retentionMs: 7 * 24 * 3600_000, maxEvents: 10_000, maxBytes: 256 * 1024 * 1024, floor: 1_000 }
    })
  }

  private member(state: Head, principal: Principal) {
    const actor = conversation.actorOf(principal)
    return state && actor ? state.participants.find((p) => p.id === actor && p.left_at === undefined) : undefined
  }

  /** Current participants, and for installs only when the grant covers reads. */
  protected maySubscribe(state: Head, principal: Principal): boolean {
    if (principal.kind !== "session" && !(principal.grant_classes ?? []).includes("read")) return false
    return this.member(state, principal) !== undefined
  }

  /**
   * Ops whose fields the Worker derives (ids, invite secret hashes, accept proofs) never run
   * from the socket: a frame would carry client-chosen values and skip the accept lock. They go
   * through POST /v1/ops; other ops may use the socket.
   */
  protected routeFrame(ws: WebSocket, _a: unknown, frame: { readonly t?: string; readonly op?: unknown; readonly idempotency_key?: unknown }): boolean {
    if (frame.t !== "op" || typeof frame.op !== "string" || !WORKER_DERIVED_OPS.has(frame.op)) return false
    try {
      ws.send(JSON.stringify({ t: "reject", tx: "", idempotency_key: frame.idempotency_key ?? "", code: "validation.invalid", message: `${frame.op} goes through POST /v1/ops`, retryable: false, replayed: false }))
    } catch {}
    return true
  }

  /** The lowest message seq a member may see (history_visible: since_join hides older ones). */
  private floor(state: Head, me: { joined_seq?: number }): number {
    return state?.settings?.history_visible === "since_join" ? (me.joined_seq ?? 0) : 0
  }

  /**
   * Events reach current members only, and never carry a message row older than the member's
   * floor. A refused event becomes a filtered snapshot for that socket (OwnerDO.broadcast).
   */
  protected mayReceive(state: Head, event: EventFrame, principal: Principal): boolean {
    const me = this.member(state, principal)
    if (!me) return false
    const floor = this.floor(state, me)
    if (floor === 0) return true
    return !(event.effects?.writes ?? []).some((w) => w.table === conversation.TABLE_MSG && w.op === "upsert" && ((w.row as { seq?: number }).seq ?? 0) <= floor)
  }

  /** Snapshot tail rows honor the member's floor too. */
  protected subscriberSnapshot(snap: ReturnType<OwnerEngine<Head>["snapshot"]>, principal: Principal): unknown {
    const base = super.subscriberSnapshot(snap, principal) as typeof snap
    const state = snap.state as Head
    const me = state ? this.member(state, principal) : undefined
    if (!base.rows || !me) return base
    const floor = this.floor(state, me)
    return floor === 0 ? base : { ...base, rows: { ...base.rows, rows: base.rows.rows.filter((r) => ((r.row as { seq?: number }).seq ?? 0) > floor) } }
  }

  /** A participant who is removed or leaves loses its sockets at once (no later events). */
  protected afterOp(_principal: Principal, _op: string, _frames: ReadonlyArray<OwnerFrame>): void {
    const state = this.boundEngine?.currentState
    if (state) this.closeSockets((p) => this.member(state, p) === undefined, "not a participant")
  }

  /** conversation.history {before_seq?, limit?}: older messages, honoring history_visible. */
  protected read(state: Head, op: string, params: unknown, principal: Principal): ReadResult {
    const me = state ? this.member(state, principal) : undefined
    if (!state || !me) return { ok: false, code: "auth.forbidden", message: "not a participant" }
    if (op === "conversation.snapshot") {
      const engine = this.boundEngine!
      const tail = typeof (params as { tail?: unknown } | null)?.tail === "number" ? (params as { tail: number }).tail : 50
      const snap = this.subscriberSnapshot(engine.snapshot(principal.identity, []), principal) as { rows?: { table: string; rows: Array<unknown> } }
      return { ok: true, value: snap.rows ? { ...snap, rows: { ...snap.rows, rows: snap.rows.rows.slice(Math.max(0, snap.rows.rows.length - tail)) } } : snap, revision: String(engine.currentSeq) }
    }
    if (op !== "conversation.history") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const q = (params ?? {}) as { before_seq?: unknown; limit?: unknown }
    const limit = typeof q.limit === "number" && q.limit > 0 ? Math.min(q.limit, MAX_HISTORY_PAGE) : 50
    const before = typeof q.before_seq === "number" ? q.before_seq : undefined
    const floor = this.floor(state, me)
    const engine = this.boundEngine!
    const rows = engine.rows.range<conversation.Message>(conversation.TABLE_MSG, { ...(before === undefined ? {} : { before }), after: floor, limit, desc: true })
    return { ok: true, value: { messages: rows.reverse().map((r) => r.row), has_more: rows.length === limit }, revision: "" }
  }

  /**
   * Anonymous, by link code: the inviter's first name for the Open Graph card. Answers only
   * while an invite is open, and never for a user-to-user DM (a DM answers only while its
   * peer is still the invited address).
   */
  async card(entity: string): Promise<{ first_name: string; avatar_url: null } | null> {
    const state = this.existingState(entity)
    const open = state?.invites?.find((i) => isOpen(i))
    if (!state || !open) return null
    if (state.kind === "dm" && !state.participants.some((p) => p.id === open.address && p.left_at === undefined)) return null
    const inviter = state.participants.find((p) => p.id === open.invited_by)
    const name = firstName(inviter?.display_name)
    return name ? { first_name: name, avatar_url: null } : null
  }

  /**
   * invite.accept from the Worker (proof = sha256(secret)). A user with 10 failed accepts in the
   * last hour on this conversation is refused before the owner runs (home-core acceptLocked), so
   * a link cannot be guessed by retrying; failures are kept in a private table, never in events.
   */
  async acceptInvite(entity: string, principal: Principal, proof: string, idempotencyKey: string): Promise<SubmitResult> {
    // An invite code for a conversation that does not exist: refused with no write (no lock table either).
    if (!this.existingState(entity)) {
      return { frames: [{ t: "reject", tx: "", idempotency_key: idempotencyKey, code: "unknown_invite", message: "the invite link is not valid", retryable: false, replayed: false } as OwnerFrame] }
    }
    const who = principal.user ?? principal.identity
    const sql = this.sqlStore
    sql.exec(`CREATE TABLE IF NOT EXISTS home_accept_failures (who TEXT NOT NULL, at INTEGER NOT NULL)`)
    const now = Date.now()
    sql.exec(`DELETE FROM home_accept_failures WHERE at <= ?`, now - invites.HOUR)
    const failures = sql.exec<{ at: number }>(`SELECT at FROM home_accept_failures WHERE who = ?`, who).map((r) => Number(r.at))
    if (invites.acceptLocked({ failures }, now)) {
      return { frames: [{ t: "reject", tx: "", idempotency_key: idempotencyKey, code: "accept_locked", message: "too many failed attempts; try again later", retryable: true, replayed: false } as OwnerFrame] }
    }
    const res = await this.submit(entity, principal, { t: "op", op: "invite.accept", params: { proof }, idempotency_key: idempotencyKey, origin: "user" })
    const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
    if (reply?.t === "reject" && ACCEPT_FAILURES.has(reply.code)) sql.exec(`INSERT INTO home_accept_failures (who, at) VALUES (?, ?)`, who, now)
    return res
  }

  /**
   * Whether `principal` is a current participant of an existing conversation. The Worker asks
   * before invite.create stashes a secret and a raw address in an AddressDO, so a stranger can
   * never make AddressDOs for conversations it is not in (security review P2), and before
   * participants.add resolves reach facts (home-reach.ts). Never writes.
   */
  async mayInvite(entity: string, principal: Principal): Promise<boolean> {
    const state = this.existingState(entity)
    const actor = conversation.actorOf(principal)
    return !!state && actor !== undefined && state.participants.some((p) => p.id === actor && p.left_at === undefined)
  }

  /** Anonymous, by secret: who invited the holder. The secret is hashed twice, as the domain stores it. */
  async invitePreview(entity: string, secret: string): Promise<InvitePreviewResult> {
    const state = this.existingState(entity)
    if (!state) return { state: "invalid" }
    const tokenHash = invites.hashInviteSecret(invites.hashInviteSecret(secret))
    const ref = this.boundEngine!.rows.get<{ invite_id: string }>(conversation.TABLE_INVHASH, tokenHash)?.row
    const invite = ref ? this.boundEngine!.rows.get<conversation.Invite>(conversation.TABLE_INV, ref.invite_id)?.row : undefined
    if (!invite) return { state: "invalid" }
    if (!isOpen(invite) || Date.parse(invite.expires_at) <= Date.now()) return { state: "expired" }
    const inviter = state.participants.find((p) => p.id === invite.invited_by)
    return {
      state: "ok",
      inviter: firstName(inviter?.display_name) ?? "Someone",
      kind: state.kind === "dm" ? "dm" : "group",
      ...(state.kind === "group" && state.title ? { title: state.title } : {})
    }
  }

  /**
   * Worker only (home-reach.ts): the reach facts this DM gives `adder` about `target`. `peer` is
   * the target's name while both are current human participants; `consented` holds when the
   * pair gave consent (16.8): both have sent a message here, or the DM came from an invite one of
   * them sent and the other accepted (16.4). Authorship comes from the `msgkey` rows, keyed
   * `<author>:<client_msg_id>`, so the check is an index range read, not a history scan.
   */
  async homeDmLink(entity: string, adder: string, target: string): Promise<{ peer: string | null; consented: boolean } | null> {
    const state = this.existingState(entity)
    if (!state || state.kind !== "dm") return null
    const current = (id: string) => state.participants.find((p) => p.id === id && p.kind === "human" && p.left_at === undefined)
    if (!current(adder)) return null
    const peer = current(target)
    if (!peer) return { peer: null, consented: false }
    const rows = tablesFor().rows
    const authored = (who: string) =>
      this.sqlStore.exec<{ one: number }>(`SELECT 1 AS one FROM ${rows} WHERE tbl = ? AND k >= ? AND k < ? LIMIT 1`, conversation.TABLE_MSGKEY, `${who}:`, `${who};`).length > 0
    const pair = new Set([adder, target])
    const invited = () =>
      [...(state.invites ?? []), ...this.boundEngine!.rows.scan<conversation.Invite>(conversation.TABLE_INV, 1000).map((r) => r.row)].some(
        (i) => i.status === "accepted" && i.accepted_by !== undefined && i.invited_by !== i.accepted_by && pair.has(i.invited_by) && pair.has(i.accepted_by)
      )
    return { peer: peer.display_name, consented: (authored(adder) && authored(target)) || invited() }
  }

  /** State of an object that already serves this conversation; never creates storage for unknown ids. */
  private existingState(entity: string): Head | undefined {
    const row = this.boundRow()
    if (!row || row.entity !== entity) return undefined
    return this.bind(entity).currentState ?? undefined
  }
}
