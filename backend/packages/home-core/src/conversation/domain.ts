import { hashInviteSecret } from "../invites/token.ts"
import { apply, targetMessageId } from "./apply.ts"
import { attachmentRefWrites, checkAttachments, type AttachmentLookup } from "./attachments.ts"
import { isOpen } from "./cloud.ts"
import { withConsentMarkers } from "./consent.ts"
import { create, summary } from "./create.ts"
import type { Domain, Principal, ReduceContext, ReduceResult, RowReader, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { formatRfc3339Millis } from "./ids.ts"
import { IMPORT_OPS, reduceImport } from "./import.ts"
import { mentionsOf, type UnreadCounts } from "./fanout.ts"
import { commitOutbox, createOutbox } from "./outbox.ts"
import { focusOf, isLarge, namedBy, needsPromotion, promote, recordOf, settle, viewHead } from "./large.ts"
import { closedGrant, closeLostGrants, grantExpired, TABLE_GRANT, TABLE_GRANTHASH } from "./grants.ts"
import { actorOf, defaultParticipantPolicy, FALLBACK_NAME, stampParticipant, type ParticipantPolicy } from "./policy.ts"
import type { Commit, OpRequest } from "./request.ts"
import { SYSTEM_ACTOR, type ClosedGrant, type ConversationHead, type ConversationKind, type Grant, type Invite, type Message, type Op, type Participant } from "./types.ts"
import { currentParticipant, safeDisplayName } from "./validate.ts"
import { NOT_REACHABLE } from "./reach.ts"
import { reduceSweep, SWEEP_OP } from "./sweep.ts"
import { inviteWrites, msgKey, TABLE_BAN, TABLE_INV, TABLE_INVHASH, TABLE_MSG, TABLE_MSGKEY, TABLE_UNREAD, UNREAD_RECOUNT_LIMIT } from "./tables.ts"

export { actorOf } from "./policy.ts"

/**
 * The ConversationDO domain (home-messaging.md section 3): the pure core
 * (`create`, `apply`) behind the ownership engine's row mode. Run it with
 * `rowMode: { snapshotTable: "msg" }`.
 *
 * Row tables:
 * - `msg`: key = message id, n = seq, row = Message.
 * - `msgkey`: key = `<author>:<client_msg_id>`, row = { message_id } (one message per author and client id).
 * - `inv`: key = invite id, row = Invite (every invite, also closed ones).
 * - `invhash`: key = token hash, row = { invite_id }.
 * - `attref`: key = `<hash>:<message id>`, row = { hash, message_id, seq } (private; attachments.ts).
 * - `ban`: key = participant id, row = { by, at }; a person removed with `ban` (roles.ts), private.
 * - `consent`: key = author id, row = { at }; a DM author's private consent marker (consent.ts),
 *   never deleted by retention.
 *
 * The head (engine state) keeps only open invites, so it stays small.
 *
 * Invite secrets: events carry params, and the engine has no redaction hook.
 * So no op carries anything that can accept. The Worker computes
 * `proof = hashInviteSecret(secret)`; `invite.create` carries
 * `token_hash = hashInviteSecret(proof)`; `invite.accept` carries `proof`,
 * which the Domain hashes. A token hash seen in an event or row is useless,
 * and a proof appears only in the accept event, after its single use.
 */
export { inviteWrites, msgKey, TABLE_BAN, TABLE_INV, TABLE_INVHASH, TABLE_MSG, TABLE_MSGKEY, TABLE_UNREAD, UNREAD_RECOUNT_LIMIT } from "./tables.ts"

export type ConversationState = ConversationHead | null
export type ConversationParams = Readonly<Record<string, unknown>>

export interface ConversationDomainOptions {
  /**
   * Address ids of the principal's verified addresses (HMAC with
   * HOME_ADDRESS_KEY over the normalized `principal.email`), injected by the
   * DO because the key is a secret. Used only when `principal.email_verified`
   * is true; otherwise a group invite waits for approval.
   */
  readonly addressIdsFor?: (principal: Principal) => ReadonlyArray<string>
  /** Reach rules for `conversation.create`, `dm.open` and `participants.add`. Default: `defaultParticipantPolicy`. */
  readonly participantPolicy?: ParticipantPolicy
  /**
   * The conversation's verified uploads (the DO's attachment store, written only after the
   * Worker hashed the bytes). An attachment part is accepted only when its hash is found here
   * with the same type and size. Absent = no uploads: every attachment part is refused.
   */
  readonly attachmentFor?: AttachmentLookup
}

const NO_ATTACHMENTS: AttachmentLookup = () => undefined
const MESSAGE_PART_OPS = new Set(["message.send", "message.edit", "message.retract"])

const refuse = (code: string): ReduceResult<ConversationState> => ({ ok: false, code, message: code })

const CREATE_OPS = new Set(["conversation.create", "dm.open"])

const reduceCreate = (
  state: ConversationState,
  op: string,
  params: ConversationParams,
  ctx: ReduceContext,
  actor: string,
  policy: ParticipantPolicy
): ReduceResult<ConversationState> => {
  const kind: ConversationKind = op === "dm.open" ? "dm" : params.kind === "chief" ? "chief" : "group"
  if (state) {
    // dm.open is idempotent by id, and answers only its participants.
    if (op === "dm.open" && state.id === params.id) {
      if (!currentParticipant(state, actor)) return refuse("forbidden")
      return { ok: true, state, value: { conversation: summary(state, null) }, changed: false }
    }
    return refuse("conversation_exists")
  }
  if (typeof params.id !== "string") return refuse("unknown_conversation")
  const raw = Array.isArray(params.participants) ? (params.participants as Array<Participant>) : []
  let creator = actor
  let participants: Array<Participant> = raw
  if (kind === "chief") {
    // Built by the owner's UserDO (`chief.create`): a system op whose params are trusted.
    if (actor !== SYSTEM_ACTOR || typeof params.owner !== "string") return refuse("forbidden")
    creator = params.owner
  } else {
    if (actor === SYSTEM_ACTOR || (kind === "dm" && !actor.startsWith("user_"))) return refuse("forbidden")
    // The team whose policy applies comes from the principal; absent = personal.
    if (params.team !== undefined && params.team !== null && params.team !== ctx.principal.team) return refuse("forbidden")
    participants = []
    for (const participant of raw) {
      if (typeof participant !== "object" || participant === null) return refuse("invalid_participant")
      const decision = policy(ctx.principal, participant, null)
      if (!decision.ok) return refuse(decision.code)
      participants.push(stampParticipant(participant, decision))
    }
  }
  const team = kind === "chief" ? params.team : params.team === undefined || params.team === null ? undefined : ctx.principal.team
  const result = create({
    id: params.id,
    actor: creator,
    title: typeof params.title === "string" ? params.title : "",
    participants,
    now: formatRfc3339Millis(ctx.now),
    kind,
    ...(typeof team === "string" ? { team } : {}),
    ...(typeof params.settings === "object" && params.settings !== null ? { settings: params.settings } : {}),
    ...(typeof params.retention_days === "number" ? { retention_days: params.retention_days } : {})
  })
  if (!result.ok) return refuse(result.code)
  return { ok: true, state: result.head, value: { conversation: summary(result.head, null) }, outbox: createOutbox(result.head) }
}

/** The invite an op names, from the head (open) or the rows (closed). */
const loadInvite = (head: ConversationHead, ctx: ReduceContext, op: Op): Invite | undefined => {
  let id: string | undefined
  if (op.kind === "invite.revoke" || op.kind === "invite.approve_join" || op.kind === "invite.delivery.report") id = op.invite_id
  if (op.kind === "invite.accept") id = rowsOf(ctx).get<{ invite_id: string }>(TABLE_INVHASH, op.token_hash)?.row.invite_id
  if (id === undefined || head.invites?.some((invite) => invite.id === id)) return undefined
  return rowsOf(ctx).get<Invite>(TABLE_INV, id)?.row
}

/**
 * Turns Domain params into a core op and the host-trusted request fields.
 * Returns a reject code when the params are refused before the core runs.
 */
const prepare = (
  head: ConversationHead,
  op: string,
  params: ConversationParams,
  ctx: ReduceContext,
  actor: string,
  options: ConversationDomainOptions
): { op: Op; trusted?: boolean; banned?: boolean } | string => {
  // Params never name the actor or the op kind.
  const { actor: _actor, kind: _kind, proof, ...rest } = params as Record<string, unknown>
  // A banned person never comes back through an invite either.
  if ((op === "invite.accept" || op === "invite.accept_verified") && rowsOf(ctx).get(TABLE_BAN, actor)) return "banned"
  if (op === "invite.accept_verified") {
    return { op: { kind: "invite.accept_verified", display_name: safeDisplayName(ctx.principal.display_name, FALLBACK_NAME) } }
  }
  if (op === "invite.accept") {
    if (typeof proof !== "string" || proof.length === 0 || proof.length > 256) return "unknown_invite"
    return { op: { kind: "invite.accept", token_hash: hashInviteSecret(proof), display_name: safeDisplayName(ctx.principal.display_name, FALLBACK_NAME) } }
  }
  if (op === "grant.create" && typeof rest.token_hash === "string" && rowsOf(ctx).get(TABLE_GRANTHASH, rest.token_hash)) return "duplicate_invite"
  if (op === "invite.create") {
    if (typeof rest.invite_id === "string" && rowsOf(ctx).get(TABLE_INV, rest.invite_id)) return "duplicate_invite"
    if (typeof rest.token_hash === "string" && rowsOf(ctx).get(TABLE_INVHASH, rest.token_hash)) return "duplicate_invite"
  }
  if (op === "participants.add") {
    // The caller's own membership first (the same code apply gives), so a non-member's refusal
    // never depends on the target: no probe of who is or was in the conversation.
    if (!currentParticipant(head, actor)) return "not_participant"
    // In a Chief's conversation only its owner adds people: refused before the reach facts, so a
    // teammate learns nothing about who they could reach.
    if (head.kind === "chief" && currentParticipant(head, actor)?.role !== "owner") return "forbidden"
    const participant = rest.participant
    if (typeof participant !== "object" || participant === null) return "invalid_participant"
    const decision = (options.participantPolicy ?? defaultParticipantPolicy)(ctx.principal, participant as Participant, head)
    if (!decision.ok) return decision.code
    // A Chief's conversation is shared only inside a team (cmux#25569): a connection alone is not enough.
    if (head.kind === "chief" && !sharesTeam(ctx.principal, participant as Participant)) return NOT_REACHABLE
    const role = rest.role === undefined ? {} : { role: rest.role as Participant["role"] & string }
    const banned = typeof (participant as Participant).id === "string" && rowsOf(ctx).get(TABLE_BAN, (participant as Participant).id) !== undefined
    return { op: { kind: "participants.add", participant: stampParticipant(participant as Participant, decision), ...role } as Op, trusted: true, banned }
  }
  if (op === "message.send" && typeof rest.client_msg_id === "string") {
    // The owner and the client's own intent preview pass the key; mirror replay does not.
    if (ctx.idempotencyKey !== undefined && ctx.idempotencyKey !== rest.client_msg_id) return "invalid_client_msg_id"
    if (rowsOf(ctx).get(TABLE_MSGKEY, msgKey(actor, rest.client_msg_id))) return "idempotency_conflict"
  }
  return { op: { ...rest, kind: op } as unknown as Op }
}

/** The Worker found that the caller and this person are members of one team (reach.ts `shared_team`). */
const sharesTeam = (principal: Principal, participant: Participant): boolean =>
  participant.kind !== "human" || principal.home_reach?.some((reach) => reach.user === participant.id && reach.shared_team && reach.blocked !== true) === true

/** Unread and mentions of `user` after `cursor`, from the message rows (at most UNREAD_RECOUNT_LIMIT). */
const recount = (rows: RowReader, user: string, cursor: number): UnreadCounts => {
  let unread = 0
  let mentions = 0
  for (const { row } of rows.range<Message>(TABLE_MSG, { after: cursor, limit: UNREAD_RECOUNT_LIMIT })) {
    if (row.author === user || row.retracted_at !== undefined) continue
    unread += 1
    if (mentionsOf(row).has(user)) mentions += 1
  }
  return { unread, mentions }
}

/** The lowest message seq `user` may see: with history_visible since_join, its join (ConversationDO.floor). */
const historyFloor = (head: ConversationHead, user: string): number =>
  head.settings?.history_visible === "since_join" ? (currentParticipant(head, user)?.joined_seq ?? 0) : 0

/**
 * Counts per human before this commit, for fanOut: the stored row, or a recount from the read
 * cursor when there is none (a conversation older than the table). A cursor moved back recounts.
 */
/**
 * Where a user's unread count starts: the read cursor, and with history_visible since_join never
 * below the user's join (the same floor reads, search and snapshots use).
 */
export const unreadFloor = (head: ConversationHead, user: string): number => {
  return Math.max(head.read_cursors[user] ?? 0, historyFloor(head, user))
}

const unreadBefore = (before: ConversationHead, after: ConversationHead, op: Op, rows: RowReader): Record<string, UnreadCounts> => {
  const counts: Record<string, UnreadCounts> = {}
  const wasMember = (user: string) => before.participants.some((p) => p.id === user && p.left_at === undefined)
  const humans = new Set([...before.participants, ...after.participants].filter((p) => p.kind === "human").map((p) => p.id))
  for (const user of humans) {
    // A (re)joining member starts from the floor of the head after the join, never from a stored row of an earlier membership.
    const stored = wasMember(user) ? rows.get<UnreadCounts>(TABLE_UNREAD, user)?.row : undefined
    counts[user] = stored ?? recount(rows, user, unreadFloor(wasMember(user) ? before : after, user))
  }
  // A moved cursor recounts: read_cursor.set, and a send, which moves the sender's cursor.
  for (const user of humans) if (after.read_cursors[user] !== before.read_cursors[user]) counts[user] = recount(rows, user, unreadFloor(after, user))
  return counts
}

/**
 * Link grant upkeep after a commit (grants.ts): a new grant's hash row, a redeemed grant's use
 * (closed when used up), a revoked one, and the grants whose makers this commit removed or
 * demoted. Closed grants leave the head for a `grant` row.
 */
const withGrantUpkeep = (state: ConversationHead, commit: Commit, op: Op, opActor: string, redeemed: Grant | undefined, now: string, writes: Array<RowWrite>): Commit => {
  const before = state.grants ?? []
  let grants = commit.head.grants ?? []
  if (before.length === 0 && grants.length === 0) return commit
  const closed: Array<ClosedGrant> = []
  if (op.kind === "grant.create") writes.push({ table: TABLE_GRANTHASH, op: "upsert", key: op.token_hash, n: null, row: { grant_id: op.grant_id } })
  if (op.kind === "grant.revoke") for (const grant of before) if (!grants.some((g) => g.id === grant.id) && grant.id === op.grant_id) closed.push(closedGrant(grant, "revoked", now, opActor))
  if (redeemed) {
    const used = { ...redeemed, uses: redeemed.uses + 1 }
    grants = grants.flatMap((grant) => (grant.id !== used.id ? [grant] : used.uses >= used.max_uses ? (closed.push(closedGrant(used, "used", now)), []) : [used]))
  }
  const target = (op as { participant?: unknown }).participant
  const makers = new Set([opActor, ...(typeof target === "string" ? [target] : [])])
  const { open, lost } = closeLostGrants(grants, makers, (id) => commit.head.participants.find((p) => p.id === id))
  for (const grant of lost) closed.push(closedGrant(grant, "issuer_lost_rights", now, opActor))
  for (const grant of closed) writes.push({ table: TABLE_GRANT, op: "upsert", key: grant.id, n: null, row: grant })
  const { grants: _old, ...rest } = commit.head
  return { ...commit, head: open.length > 0 ? { ...rest, grants: open } : rest }
}

/** The open invite an invite op names in the head (its address is a member row the view loads). */
const inviteNamed = (head: ConversationHead, op: Op): Invite | undefined => {
  const id = op.kind === "invite.revoke" || op.kind === "invite.approve_join" || op.kind === "invite.delivery.report" ? op.invite_id : undefined
  const hash = op.kind === "invite.accept" ? op.token_hash : undefined
  return head.invites?.find((invite) => invite.id === id || (hash !== undefined && invite.token_hash === hash))
}

/**
 * Counts before the commit for the people a large-group commit bumps (large.ts focusOf), each
 * recounted from its cursor: at most UNREAD_RECOUNT_LIMIT messages per named person, never a
 * pass over every member.
 */
const focusCounts = (before: ConversationHead, after: ConversationHead, request: OpRequest, commit: Commit, rows: RowReader): Record<string, UnreadCounts> => {
  const counts: Record<string, UnreadCounts> = {}
  for (const user of focusOf(request, commit.message)) {
    const wasMember = before.participants.some((p) => p.id === user && p.left_at === undefined)
    const record = (wasMember ? before : after).participants.find((p) => p.id === user)
    if (record?.kind !== "human") continue
    counts[user] = recount(rows, user, unreadFloor(after.read_cursors[user] !== before.read_cursors[user] || !wasMember ? after : before, user))
  }
  return counts
}

/** Ops a person who is not (yet) a participant may send: an invite redeemed, a delivery report or rename from the system, a request dismissed, the retention sweep. */
const STRANGER_OPS: ReadonlySet<string> = new Set(["invite.accept", "invite.accept_verified", "invite.delivery.report", "chief.rename", "request.dismiss", SWEEP_OP])

const reduceConversation = (
  options: ConversationDomainOptions,
  state: ConversationState,
  op: string,
  params: ConversationParams,
  ctx: ReduceContext
): ReduceResult<ConversationState> => {
  const actor = actorOf(ctx.principal)
  if (!actor) return refuse("forbidden")
  if (IMPORT_OPS.has(op)) return reduceImport(state, op, params, ctx, actor, options.participantPolicy ?? defaultParticipantPolicy)
  if (CREATE_OPS.has(op)) return reduceCreate(state, op, params, ctx, actor, options.participantPolicy ?? defaultParticipantPolicy)
  if (!state) return refuse("unknown_conversation")
  // A caller who never belonged learns nothing: the answer of an id that does not exist (tenant-isolation-DESIGN.md 5.1).
  // Someone who left keeps `not_participant`; the ops below are the ones a stranger may legitimately send.
  if (!recordOf(state, rowsOf(ctx), actor) && !STRANGER_OPS.has(op)) return refuse("unknown_conversation")
  // Inside the wrapped reduce: a retention batch that deletes msgkey rows leaves the DM's consent markers (consent.ts).
  if (op === SWEEP_OP) return reduceSweep(state, ctx, actor)
  const prepared = prepare(state, op, params, ctx, actor, options)
  if (typeof prepared === "string") return refuse(prepared)
  let coreOp = prepared.op
  // The actor the reducer sees: the caller, or for a link grant the member who made it (grants.ts).
  let opActor = actor
  let trusted = prepared.trusted ?? null
  let redeemed: Grant | undefined
  if (coreOp.kind === "invite.accept") {
    const ref = rowsOf(ctx).get<{ grant_id: string }>(TABLE_GRANTHASH, coreOp.token_hash)?.row
    if (ref) {
      // A link grant: the caller joins with the link's role, added by the link's maker.
      const grant = (state.grants ?? []).find((candidate) => candidate.id === ref.grant_id)
      if (!grant) return refuse("unknown_invite")
      if (grantExpired(grant, formatRfc3339Millis(ctx.now))) return refuse("invite_expired")
      if (ctx.principal.agent !== undefined || !actor.startsWith("user_")) return refuse("forbidden")
      redeemed = grant
      opActor = grant.issuer
      trusted = true
      coreOp = { kind: "participants.add", participant: { id: actor, kind: "human", display_name: coreOp.display_name }, role: grant.role }
    }
  }
  const loaded = loadInvite(state, ctx, coreOp)
  const messageId = targetMessageId(coreOp)
  const targetRow = messageId === undefined ? null : (rowsOf(ctx).get<Message>(TABLE_MSG, messageId)?.row ?? null)
  const lastMessage = rowsOf(ctx).range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row ?? null
  // A large group runs the op on a view head: the roster plus the member rows it names (large.ts).
  const invite = loaded ?? inviteNamed(state, coreOp)
  const maker = coreOp.kind === "grant.revoke" ? (state.grants ?? []).find((grant) => grant.id === (coreOp as { grant_id: string }).grant_id)?.issuer : undefined
  const base = isLarge(state) ? viewHead(state, rowsOf(ctx), namedBy(coreOp, opActor, [lastMessage, targetRow], [invite?.address, maker])) : state
  const head: ConversationHead = loaded ? { ...base, invites: [...(base.invites ?? []), loaded] } : base
  const replyId = coreOp.kind === "message.send" ? coreOp.reply_to?.message_id : undefined
  const threadId = coreOp.kind === "message.send" && typeof coreOp.thread_root === "string" ? coreOp.thread_root : undefined
  const floor = historyFloor(head, actor)
  const visible = (row: Message | null): Message | null => (row && row.seq > floor ? row : null)
  const threadRow = threadId === undefined ? null : (rowsOf(ctx).get<Message>(TABLE_MSG, threadId)?.row ?? null)
  const verified = (op === "invite.accept" || op === "invite.accept_verified") && ctx.principal.email_verified === true && options.addressIdsFor
  const request: OpRequest = {
    actor: opActor,
    // The engine's ledger owns idempotency; `msgkey` keeps (author, client_msg_id) unique.
    idempotency_key: coreOp.kind === "message.send" ? coreOp.client_msg_id : "",
    op: coreOp,
    now: formatRfc3339Millis(ctx.now),
    new_message_id: coreOp.kind === "message.send" ? ctx.newId("msg") : "",
    // A thread root below the actor's history floor is refused like a missing one (the thread
    // read's rule), so thread.update never probes or changes hidden history.
    target: coreOp.kind === "thread.update" ? visible(targetRow) : targetRow,
    // A reply target or thread root below the actor's history floor (since_join) is not visible
    // to it: refused like a missing one, so a send never probes hidden history.
    reply_target: visible(replyId === undefined ? null : (rowsOf(ctx).get<Message>(TABLE_MSG, replyId)?.row ?? null)),
    thread_target: visible(threadRow),
    // The loop guard lives in the head (O(1)); only the newest message is read, for summaries.
    last_message: lastMessage,
    actor_addresses: verified ? options.addressIdsFor!(ctx.principal) : null,
    trusted_participant: trusted,
    banned: prepared.banned ?? null
  }
  const result = apply(head, request)
  if (!result.ok) return refuse(result.code)
  let { commit } = result
  // A thread root derived from the parent (a reply to a thread reply that names no thread_root) must be
  // visible to the sender, like a named one: a root below its history floor is refused, never joined.
  if (coreOp.kind === "message.send" && threadId === undefined && commit.message?.thread_root !== undefined) {
    if (!visible(rowsOf(ctx).get<Message>(TABLE_MSG, commit.message.thread_root)?.row ?? null)) return refuse("invalid_thread_root")
  }
  const writes: Array<RowWrite> = []
  if (commit.message && MESSAGE_PART_OPS.has(coreOp.kind)) {
    // The author's own view: an uploader of the hash, or a referencing message above their floor.
    const me = currentParticipant(head, actor)
    const floor = head.settings?.history_visible === "since_join" ? (me?.joined_seq ?? 0) : 0
    const bad = checkAttachments(commit.message.parts, options.attachmentFor ?? NO_ATTACHMENTS, actor, floor)
    if (bad) return refuse(bad)
    writes.push(...attachmentRefWrites(coreOp.kind === "message.send" ? null : (request.target ?? null), commit.message))
  }
  if (commit.message) {
    writes.push({ table: TABLE_MSG, op: "upsert", key: commit.message.id, n: commit.message.seq, row: commit.message })
    if (coreOp.kind === "message.send") {
      writes.push({ table: TABLE_MSGKEY, op: "upsert", key: msgKey(actor, commit.message.client_msg_id), n: null, row: { message_id: commit.message.id } })
    }
  }
  writes.push(...inviteWrites(head.invites ?? [], commit.head.invites ?? []))
  if (coreOp.kind === "participants.remove" && coreOp.ban === true) {
    writes.push({ table: TABLE_BAN, op: "upsert", key: coreOp.participant, n: null, row: { by: actor, at: request.now } })
  }
  if (coreOp.kind === "participants.unban") writes.push({ table: TABLE_BAN, op: "delete", key: coreOp.participant })
  commit = withGrantUpkeep(state, commit, coreOp, opActor, redeemed, request.now, writes)
  // The head to store, and the commit the outbox describes (a large group's counts and tier).
  let stored: ConversationHead = commit.head
  let described: Commit = commit
  let everyone = false
  if (isLarge(state)) {
    const settled = settle(state, head, commit.head, rowsOf(ctx))
    writes.push(...settled.writes)
    stored = settled.head
    const { member_count, human_count, state: lifecycle } = settled.head
    described = { ...commit, head: { ...commit.head, member_count, human_count, ...(lifecycle === undefined ? {} : { state: lifecycle }) } }
  } else if (needsPromotion(commit.head)) {
    // Once, in the commit that crosses INLINE_MAX: every member's inbox learns the group is large.
    const promoted = promote(commit.head)
    writes.push(...promoted.writes)
    stored = promoted.head
    described = { ...commit, head: { ...commit.head, tier: "large", member_count: promoted.head.member_count, human_count: promoted.head.human_count } }
    everyone = true
  }
  const next: ConversationHead = stored.invites ? { ...stored, invites: stored.invites.filter(isOpen) } : stored
  const counts = isLarge(state) ? focusCounts(head, described.head, request, commit, rowsOf(ctx)) : unreadBefore(head, commit.head, coreOp, rowsOf(ctx))
  const outbox = commitOutbox(head, request, described, counts, everyone)
  // The counts each bump carries become the stored counts (the next commit starts from them).
  for (const item of outbox) {
    const p = item.payload as { user?: string; unread?: number; mentions?: number }
    if (item.kind === "inbox.bump" && p.user !== undefined && p.unread !== undefined && p.mentions !== undefined) {
      writes.push({ table: TABLE_UNREAD, op: "upsert", key: p.user, n: null, row: { unread: p.unread, mentions: p.mentions } })
    }
  }
  return {
    ok: true,
    state: next,
    value: { rev: commit.head.rev, ...(commit.message ? { seq: commit.message.seq, message_id: commit.message.id } : {}), change: commit.change },
    writes,
    outbox
  }
}

export const makeConversationDomain = (options: ConversationDomainOptions = {}): Domain<ConversationState, ConversationParams> => ({
  initial: () => null,
  // Every commit, whatever the op, gets the DM consent markers its msgkey writes need (consent.ts).
  reduce: (state, op, params, ctx) => withConsentMarkers(reduceConversation(options, state, op, params, ctx), state, ctx)
})

/** The domain with the default (pure) participant policy and no verified-address binding (tests, self-hosted without the address key). */
export const conversationDomain = makeConversationDomain()
