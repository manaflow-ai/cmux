import { hashInviteSecret } from "../invites/token.ts"
import { apply, targetMessageId } from "./apply.ts"
import { isOpen } from "./cloud.ts"
import { create, summary } from "./create.ts"
import type { Domain, Principal, ReduceContext, ReduceResult, RowReader, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { formatRfc3339Millis } from "./ids.ts"
import { IMPORT_OPS, reduceImport } from "./import.ts"
import { mentionsOf, type UnreadCounts } from "./fanout.ts"
import { commitOutbox, createOutbox } from "./outbox.ts"
import { actorOf, defaultParticipantPolicy, FALLBACK_NAME, stampParticipant, type ParticipantPolicy } from "./policy.ts"
import type { OpRequest } from "./request.ts"
import { SYSTEM_ACTOR, type ConversationHead, type ConversationKind, type Invite, type Message, type Op, type Participant } from "./types.ts"
import { currentParticipant, safeDisplayName } from "./validate.ts"

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
export const TABLE_MSG = "msg"
export const TABLE_MSGKEY = "msgkey"
export const TABLE_INV = "inv"
export const TABLE_INVHASH = "invhash"
/** Per-user unread and mention counts (key = user id), kept by the owner for inbox bumps; private. */
export const TABLE_UNREAD = "unread"
/** A recount (a cursor moved back, or a conversation older than the table) reads at most this many messages. */
export const UNREAD_RECOUNT_LIMIT = 1000

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
}

const refuse = (code: string): ReduceResult<ConversationState> => ({ ok: false, code, message: code })

export const msgKey = (author: string, clientMsgId: string) => `${author}:${clientMsgId}`

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

const inviteWrites = (before: ReadonlyArray<Invite>, after: ReadonlyArray<Invite>): Array<RowWrite> => {
  const writes: Array<RowWrite> = []
  for (const invite of after) {
    const old = before.find((candidate) => candidate.id === invite.id)
    if (old && JSON.stringify(old) === JSON.stringify(invite)) continue
    writes.push({ table: TABLE_INV, op: "upsert", key: invite.id, n: null, row: invite })
    if (!old) writes.push({ table: TABLE_INVHASH, op: "upsert", key: invite.token_hash, n: null, row: { invite_id: invite.id } })
  }
  return writes
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
): { op: Op; trusted?: boolean } | string => {
  // Params never name the actor or the op kind.
  const { actor: _actor, kind: _kind, proof, ...rest } = params as Record<string, unknown>
  if (op === "invite.accept") {
    if (typeof proof !== "string" || proof.length === 0 || proof.length > 256) return "unknown_invite"
    return { op: { kind: "invite.accept", token_hash: hashInviteSecret(proof), display_name: safeDisplayName(ctx.principal.display_name, FALLBACK_NAME) } }
  }
  if (op === "invite.create") {
    if (typeof rest.invite_id === "string" && rowsOf(ctx).get(TABLE_INV, rest.invite_id)) return "duplicate_invite"
    if (typeof rest.token_hash === "string" && rowsOf(ctx).get(TABLE_INVHASH, rest.token_hash)) return "duplicate_invite"
  }
  if (op === "participants.add") {
    const participant = rest.participant
    if (typeof participant !== "object" || participant === null) return "invalid_participant"
    const decision = (options.participantPolicy ?? defaultParticipantPolicy)(ctx.principal, participant as Participant, head)
    if (!decision.ok) return decision.code
    return { op: { kind: "participants.add", participant: stampParticipant(participant as Participant, decision) }, trusted: true }
  }
  if (op === "message.send" && typeof rest.client_msg_id === "string") {
    // The owner and the client's own intent preview pass the key; mirror replay does not.
    if (ctx.idempotencyKey !== undefined && ctx.idempotencyKey !== rest.client_msg_id) return "invalid_client_msg_id"
    if (rowsOf(ctx).get(TABLE_MSGKEY, msgKey(actor, rest.client_msg_id))) return "idempotency_conflict"
  }
  return { op: { ...rest, kind: op } as unknown as Op }
}

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

/**
 * Counts per human before this commit, for fanOut: the stored row, or a recount from the read
 * cursor when there is none (a conversation older than the table). A cursor moved back recounts.
 */
/**
 * Where a user's unread count starts: the read cursor, and with history_visible since_join never
 * below the user's join (the same floor reads, search and snapshots use).
 */
const unreadFloor = (head: ConversationHead, user: string): number => {
  const cursor = head.read_cursors[user] ?? 0
  if (head.settings?.history_visible !== "since_join") return cursor
  const joined = head.participants.find((p) => p.id === user && p.left_at === undefined)?.joined_seq ?? 0
  return Math.max(cursor, joined)
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
  if (op.kind === "read_cursor.set") for (const user of humans) if (after.read_cursors[user] !== before.read_cursors[user]) counts[user] = recount(rows, user, unreadFloor(after, user))
  return counts
}

export const makeConversationDomain = (options: ConversationDomainOptions = {}): Domain<ConversationState, ConversationParams> => ({
  initial: () => null,
  reduce: (state, op, params, ctx) => {
    const actor = actorOf(ctx.principal)
    if (!actor) return refuse("forbidden")
    if (IMPORT_OPS.has(op)) return reduceImport(state, op, params, ctx, actor, options.participantPolicy ?? defaultParticipantPolicy)
    if (CREATE_OPS.has(op)) return reduceCreate(state, op, params, ctx, actor, options.participantPolicy ?? defaultParticipantPolicy)
    if (!state) return refuse("unknown_conversation")
    const prepared = prepare(state, op, params, ctx, actor, options)
    if (typeof prepared === "string") return refuse(prepared)
    const coreOp = prepared.op
    const loaded = loadInvite(state, ctx, coreOp)
    const head: ConversationHead = loaded ? { ...state, invites: [...(state.invites ?? []), loaded] } : state
    const messageId = targetMessageId(coreOp)
    const replyId = coreOp.kind === "message.send" ? coreOp.reply_to?.message_id : undefined
    const verified = op === "invite.accept" && ctx.principal.email_verified === true && options.addressIdsFor
    const request: OpRequest = {
      actor,
      // The engine's ledger owns idempotency; `msgkey` keeps (author, client_msg_id) unique.
      idempotency_key: coreOp.kind === "message.send" ? coreOp.client_msg_id : "",
      op: coreOp,
      now: formatRfc3339Millis(ctx.now),
      new_message_id: coreOp.kind === "message.send" ? ctx.newId("msg") : "",
      target: messageId === undefined ? null : (rowsOf(ctx).get<Message>(TABLE_MSG, messageId)?.row ?? null),
      reply_target: replyId === undefined ? null : (rowsOf(ctx).get<Message>(TABLE_MSG, replyId)?.row ?? null),
      // The loop guard lives in the head (O(1)); only the newest message is read, for summaries.
      last_message: rowsOf(ctx).range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row ?? null,
      actor_addresses: verified ? options.addressIdsFor!(ctx.principal) : null,
      trusted_participant: prepared.trusted ?? null
    }
    const result = apply(head, request)
    if (!result.ok) return refuse(result.code)
    const { commit } = result
    const writes: Array<RowWrite> = []
    if (commit.message) {
      writes.push({ table: TABLE_MSG, op: "upsert", key: commit.message.id, n: commit.message.seq, row: commit.message })
      if (coreOp.kind === "message.send") {
        writes.push({ table: TABLE_MSGKEY, op: "upsert", key: msgKey(actor, commit.message.client_msg_id), n: null, row: { message_id: commit.message.id } })
      }
    }
    writes.push(...inviteWrites(head.invites ?? [], commit.head.invites ?? []))
    const next: ConversationHead = commit.head.invites ? { ...commit.head, invites: commit.head.invites.filter(isOpen) } : commit.head
    const counts = unreadBefore(head, commit.head, coreOp, rowsOf(ctx))
    const outbox = commitOutbox(head, request, commit, counts)
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
})

/** The domain with the default (pure) participant policy and no verified-address binding (tests, self-hosted without the address key). */
export const conversationDomain = makeConversationDomain()
