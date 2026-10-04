import type { Domain, EventFrame, OwnerEngine, OwnerFrame, Principal } from "@cmux/ownership"
import { conversation, invites } from "@cmux/home-core"

/** An invite still waiting for its recipient (pending, or waiting for approval). */
const isOpen = (i: conversation.Invite) => i.status === "pending" || i.status === "pending_approval"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult, type SubmitResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"
import { withAdmit } from "./home-admit.ts"
import * as store from "./home-attachment-store.ts"

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

/** What the Worker learns about an attachment hash for one caller (never whether another conversation holds it). */
export type AttachmentAccess =
  | { readonly ok: false; readonly code: "auth.forbidden"; readonly message: string }
  | { readonly ok: true; readonly open: boolean; readonly record: conversation.AttachmentRecord | null }

/** A download the owner allows: the record, and (when asked by message part) that part, whose name is the file name. */
export type DownloadAccess = { readonly record: conversation.AttachmentRecord; readonly name: string | null; readonly part?: conversation.AttachmentPart } | null

type Users = { releaseAttachmentStorage(e: string, key: string): Promise<void>; refundAttachmentQuota(e: string, slot: string): Promise<void> }

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
    const sql = { exec: <T>(q: string, ...b: Array<unknown>) => ctx.storage.sql.exec(q, ...b).toArray() as Array<T> }
    const domain = conversation.makeConversationDomain({
      participantPolicy: ownerRecordPolicy,
      // Verified uploads the author may use (home-attachment-store.ts); a read inside the reducer, no write.
      attachmentFor: (hash, actor, floor) => store.usableRecord(sql, hash, actor, floor) ?? undefined,
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
  protected afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>): void {
    const state = this.boundEngine?.currentState
    if (state) this.closeSockets((p) => this.member(state, p) === undefined, "not a participant")
    // A retract or an edit may release attachment references: older uploads may now be collectable.
    if ((op === "message.retract" || op === "message.edit") && frames.some((f) => f.t === "result")) store.markDirty(this.sqlStore, Date.now())
  }

  /** The alarm also expires upload slots and runs the attachment sweep (shared with the outbox drain and the prunes). */
  protected override nextWakeAt(_state: Head, _now: number): number | null {
    const times = [store.nextSweepAt(this.sqlStore), store.nextSlotDue(this.sqlStore), store.purgeAt(this.sqlStore)].filter((t): t is number => t !== null)
    return times.length ? Math.min(...times) : null
  }

  protected override async onWake(now: number): Promise<void> {
    await this.expireSlots(now)
    const due = store.nextSweepAt(this.sqlStore)
    if (due !== null && due <= now) await this.sweepAttachments(now)
    const purge = store.purgeAt(this.sqlStore)
    const entity = this.boundRow()?.entity
    if (purge !== null && purge <= now && entity) {
      await this.deletePrefix(entity)
      store.clearPurge(this.sqlStore, purge)
    }
  }

  private users(user: string): Users {
    return this.env.USER_DO.get(this.env.USER_DO.idFromName(user)) as unknown as Users
  }

  /**
   * Slots whose time is up: their object key is deleted (a PUT that never committed, or a re-PUT
   * to a presigned URL after the slot ended), a slot that never committed is refunded, then the
   * row goes. Each step is idempotent, so a failed wake retries safely.
   */
  private async expireSlots(now: number): Promise<void> {
    for (;;) {
      const due = store.dueSlots(this.sqlStore, now, 100)
      if (due.length === 0) return
      if (this.env.HOME_ATTACHMENTS) await this.env.HOME_ATTACHMENTS.delete(due.flatMap(store.slotKeys))
      for (const slot of due) {
        if (slot.state !== "tombstone") await this.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
        store.removeSlot(this.sqlStore, slot.id)
      }
      if (due.length < 100) return
    }
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
   * never make AddressDOs for conversations it is not in (security review P2). Never writes.
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

  /** A current, acting participant (not an address) of an existing conversation, with the state. */
  private acting(entity: string, actor: string) {
    const state = this.existingState(entity)
    const me = state?.participants.find((p) => p.id === actor && p.left_at === undefined && p.kind !== "address")
    return state && me ? { state, me, open: state.state !== "archived" && state.state !== "importing" } : undefined
  }

  /**
   * The Worker's attachment check for `actor` (a current participant only): whether the
   * conversation takes new uploads, and the record of `hash` when this actor may use it (an
   * uploader, or referenced by a message after the actor's history floor). Never writes.
   */
  async attachmentAccess(entity: string, actor: string, hash: string): Promise<AttachmentAccess> {
    const a = this.acting(entity, actor)
    if (!a) return { ok: false, code: "auth.forbidden", message: "not a participant of this conversation" }
    return { ok: true, open: a.open, record: store.usableRecord(this.sqlStore, hash, actor, this.floor(a.state, a.me)) }
  }

  /** After the participant and quota checks: a single-use upload slot with a fresh object id. */
  async createUploadSlot(
    entity: string,
    actor: string,
    quotaUser: string,
    meta: { hash: string; byte_count: number; mime_type: string; derived?: conversation.DerivedImage },
    mode: store.UploadSlot["mode"],
    id: string
  ): Promise<store.UploadSlot | null> {
    const a = this.acting(entity, actor)
    if (!a || !a.open || !/^[0-9a-f]{32}$/.test(id)) return null
    const objectId = store.randomId()
    const slot: store.UploadSlot = { id, ...meta, actor, quota_user: quotaUser, object_id: objectId, object_key: conversation.attachmentObjectKey(entity, objectId), mode, expires_at: Date.now() + conversation.ATTACHMENT_LIMITS.uploadTtlMs }
    store.createSlot(this.sqlStore, slot)
    // The slot's expiry is an alarm time: its object (if any) goes then unless a commit kept it.
    this.scheduleAlarm()
    return slot
  }

  /** The live slot; `consume` makes it unusable from now on (single use). `actor` when the caller is authenticated. */
  async uploadSlot(entity: string, id: string, mode: store.UploadSlot["mode"], consume: boolean, actor?: string): Promise<store.UploadSlot | null> {
    if (!this.existingState(entity)) return null
    return store.takeSlot(this.sqlStore, id, mode, consume, actor)
  }

  /** The open slot whose declared poster or preview may be PUT now (moved to `uploading`). */
  async derivedSlot(entity: string, id: string): Promise<store.UploadSlot | null> {
    if (!this.existingState(entity)) return null
    return store.takeDerived(this.sqlStore, id)
  }

  /** Ends a poster or preview PUT: its etag when verified, null when refused (the client may PUT again). */
  async settleDerived(entity: string, id: string, etag: string | null): Promise<void> {
    if (this.existingState(entity)) store.settleDerived(this.sqlStore, id, etag)
  }

  /** Ends an `uploading` slot whose bytes failed verification (the Worker deleted its object). */
  async settleSlot(entity: string, id: string): Promise<void> {
    if (!this.existingState(entity)) return
    const slot = store.slotIn(this.sqlStore, id, "uploading")
    if (slot) store.settleSlot(this.sqlStore, slot, false)
  }

  /**
   * After the Worker verified the bytes of `uploading` slot `slotId`: records the upload for a
   * still-current participant of an open conversation and settles the slot in the same step.
   * `exists`: the bytes were already here, the caller deletes the slot's object and refunds.
   */
  async commitAttachment(
    entity: string,
    slotId: string,
    etag?: string
  ): Promise<{ ok: true; state: "stored" | "exists"; object_key: string; derived?: conversation.DerivedImage } | { ok: false; code: "auth.forbidden" | "archived" | "slot_gone" }> {
    if (!this.existingState(entity)) return { ok: false, code: "slot_gone" }
    const slot = store.slotIn(this.sqlStore, slotId, "uploading")
    if (!slot) return { ok: false, code: "slot_gone" }
    const a = this.acting(entity, slot.actor)
    if (!a || !a.open) {
      store.settleSlot(this.sqlStore, slot, false)
      return { ok: false, code: a ? "archived" : "auth.forbidden" }
    }
    // The poster or preview goes into the record only once verified (the Worker refuses to commit while a declared one is missing).
    const variant = conversation.derivedVariantOf(slot.mime_type)
    const image = slot.derived && slot.derived_state === "stored" && variant ? { [variant]: { ...slot.derived, ...(slot.derived_etag ? { etag: slot.derived_etag } : {}) } } : {}
    const r = store.commitRecord(this.sqlStore, { hash: slot.hash, object_id: slot.object_id, object_key: slot.object_key, mime_type: slot.mime_type, byte_count: slot.byte_count, ...(etag ? { etag } : {}), ...image, uploader: slot.actor, quota_user: slot.quota_user, created_at: Date.now() })
    store.settleSlot(this.sqlStore, slot, r.record.object_key === slot.object_key)
    this.scheduleAlarm()
    const kept = conversation.recordedImageOf(r.record)?.image
    return { ok: true, state: r.state, object_key: r.record.object_key, ...(kept ? { derived: { hash: kept.hash, mime_type: kept.mime_type, byte_count: kept.byte_count } } : {}) }
  }

  /** Part `partIndex` of a message `actor` can see, when that part holds `hash`; undefined otherwise. */
  private attachmentPartAt(state: Head, me: { joined_seq?: number }, messageId: string, partIndex: number, hash: string): conversation.AttachmentPart | undefined {
    const msg = this.boundEngine!.rows.get<conversation.Message>(conversation.TABLE_MSG, messageId)?.row
    if (!msg || msg.retracted_at !== undefined || msg.seq <= this.floor(state, me)) return undefined
    const part = msg.parts[partIndex]
    return part?.type === "attachment" && part.hash === hash ? part : undefined
  }

  /** For URL mints (by hash) and downloads (by object id): the usable record and the part's name. */
  async downloadAccess(entity: string, actor: string, by: { hash: string } | { object_id: string }, at?: { message_id: string; part_index: number }): Promise<DownloadAccess | "forbidden"> {
    const a = this.acting(entity, actor)
    if (!a) return "forbidden"
    const found = "hash" in by ? store.attachmentRecord(this.sqlStore, by.hash) : store.recordByObjectId(this.sqlStore, by.object_id)
    const record = found ? store.usableRecord(this.sqlStore, found.hash, actor, this.floor(a.state, a.me)) : null
    if (!record) return null
    if (!at) return { record, name: null }
    const part = this.attachmentPartAt(a.state, a.me, at.message_id, at.part_index, record.hash)
    return part === undefined ? null : { record, name: part.name, part }
  }

  /** Unreferenced uploads past the grace period: forget, delete their objects, release the uploaders' storage. */
  private async sweepAttachments(now: number): Promise<number> {
    const { records, done } = store.sweepBatch(this.sqlStore, now - conversation.ATTACHMENT_LIMITS.unreferencedGraceMs)
    await this.dropObjects(records)
    store.markSwept(this.sqlStore, now, done)
    return records.length
  }

  private async dropObjects(records: ReadonlyArray<conversation.AttachmentRecord>): Promise<void> {
    if (records.length && this.env.HOME_ATTACHMENTS) await this.env.HOME_ATTACHMENTS.delete(records.flatMap(store.recordKeys))
    for (const r of records) {
      try {
        await this.users(r.quota_user).releaseAttachmentStorage(r.quota_user, r.object_key)
      } catch (e) {
        // Fails safe: the uploader's stored-bytes count stays high until a later release.
        console.error(JSON.stringify({ msg: "attachment storage release failed", error: String(e) }))
      }
    }
  }

  /** Runs the sweep now (tests and operators); the alarm runs the same code when due. */
  async collectAttachments(entity: string, now = Date.now()): Promise<number> {
    return this.existingState(entity) ? this.sweepAttachments(now) : 0
  }

  /**
   * Conversation storage deletion: forgets every record and slot, deletes every object under
   * `home/v1/<conversation>/` (also orphans of failed uploads) and releases the uploaders' storage.
   * A dropped slot's URL may still finish a PUT after this (S3 checks expiry only at the start),
   * so the prefix is deleted again by the alarm once the latest dropped slot is past its expiry
   * plus the upload grace. The deletion path that calls it (no human for 30 days, section 10)
   * does not exist yet; the conversation takes no new uploads by then (archived).
   */
  async deleteAttachmentStorage(entity: string): Promise<number> {
    if (!this.existingState(entity) || !this.env.HOME_ATTACHMENTS) return 0
    const { records, slots } = store.forgetAll(this.sqlStore)
    if (slots.length) {
      store.schedulePurge(this.sqlStore, Math.max(...slots.map((s) => s.expires_at)) + store.UPLOADING_GRACE_MS)
      this.scheduleAlarm()
    }
    await this.dropObjects(records)
    for (const slot of slots) if (slot.state !== "tombstone") await this.users(slot.quota_user).refundAttachmentQuota(slot.quota_user, slot.id)
    const known = new Set(records.flatMap(store.recordKeys))
    return records.length + (await this.deletePrefix(entity)).filter((k) => !known.has(k)).length
  }

  /** Deletes every object under `home/v1/<conversation>/`; answers the keys it deleted. */
  private async deletePrefix(entity: string): Promise<Array<string>> {
    const bucket = this.env.HOME_ATTACHMENTS
    if (!bucket) return []
    const deleted: Array<string> = []
    let cursor: string | undefined
    do {
      const page = await bucket.list({ prefix: conversation.attachmentPrefix(entity), ...(cursor ? { cursor } : {}) })
      if (page.objects.length) {
        await bucket.delete(page.objects.map((o) => o.key))
        deleted.push(...page.objects.map((o) => o.key))
      }
      cursor = page.truncated ? page.cursor : undefined
    } while (cursor)
    return deleted
  }

  /** State of an object that already serves this conversation; never creates storage for unknown ids. */
  private existingState(entity: string): Head | undefined {
    const row = this.boundRow()
    if (!row || row.entity !== entity) return undefined
    return this.bind(entity).currentState ?? undefined
  }
}
