import { hashInviteSecret } from "../invites/token.ts"
import { apply, targetMessageId } from "./apply.ts"
import { BUDGET_WINDOW } from "./budget.ts"
import { isOpen } from "./cloud.ts"
import { create, summary } from "./create.ts"
import type { Domain, Principal, ReduceContext, ReduceResult, RowWrite } from "./engine-types.ts"
import { formatRfc3339Millis } from "./ids.ts"
import { commitOutbox, createOutbox } from "./outbox.ts"
import type { OpRequest } from "./request.ts"
import { SYSTEM_ACTOR, type ConversationHead, type ConversationKind, type Invite, type Message, type Op } from "./types.ts"

/**
 * The ConversationDO domain (home-messaging.md section 3): the pure core
 * (`create`, `apply`) behind the ownership engine's row mode. Run it with
 * `rowMode: { snapshotTable: "msg" }`.
 *
 * Row tables:
 * - `msg`: key = message id, n = seq, row = Message.
 * - `msgkey`: key = client_msg_id, row = { message_id } (one message per client id).
 * - `inv`: key = invite id, row = Invite (every invite, also closed ones).
 * - `invhash`: key = token hash, row = { invite_id }.
 *
 * The head (engine state) keeps only open invites, so it stays small.
 */
export const TABLE_MSG = "msg"
export const TABLE_MSGKEY = "msgkey"
export const TABLE_INV = "inv"
export const TABLE_INVHASH = "invhash"

export type ConversationState = ConversationHead | null
export type ConversationParams = Readonly<Record<string, unknown>>

export interface ConversationDomainOptions {
  /**
   * Contact ids of the principal's verified addresses (HMAC with
   * HOME_CONTACT_KEY over the normalized `principal.email`), injected by the DO
   * because the key is a secret. Without it, group email invites always wait
   * for approval.
   */
  readonly contactIdsFor?: (principal: Principal) => ReadonlyArray<string>
}

const refuse = (code: string): ReduceResult<ConversationState> => ({ ok: false, code, message: code })

const prefixed = (prefix: string, id: string) => (id.startsWith(prefix) ? id : `${prefix}${id}`)

/** The actor id from the authenticated principal, never from params. */
export const actorOf = (principal: Principal): string | null => {
  if (principal.kind === "system") return SYSTEM_ACTOR
  if (principal.agent) return prefixed("agent_", principal.agent)
  if (principal.user) return prefixed("user_", principal.user)
  return null
}

const CREATE_KINDS: Readonly<Record<string, ConversationKind>> = { "conversation.create": "group", "dm.open": "dm" }

const reduceCreate = (state: ConversationState, op: string, params: ConversationParams, ctx: ReduceContext, actor: string): ReduceResult<ConversationState> => {
  const kind: ConversationKind = op === "dm.open" ? "dm" : params.kind === "chief" ? "chief" : "group"
  if (state) {
    // dm.open is idempotent by id; a second create of the same id is a no-op only for dms.
    if (op === "dm.open" && state.id === params.id) return { ok: true, state, value: { conversation: summary(state, null) }, changed: false }
    return refuse("conversation_exists")
  }
  // A chief conversation is created by its owner's UserDO (`chief.create`), on behalf of `params.owner`.
  let creator = actor
  if (kind === "chief") {
    if (actor !== SYSTEM_ACTOR || typeof params.owner !== "string") return refuse("forbidden")
    creator = params.owner
  } else if (actor === SYSTEM_ACTOR || (kind === "dm" && !actor.startsWith("user_"))) {
    return refuse("forbidden")
  }
  if (typeof params.id !== "string") return refuse("unknown_conversation")
  const result = create({
    id: params.id,
    actor: creator,
    title: typeof params.title === "string" ? params.title : "",
    participants: Array.isArray(params.participants) ? params.participants : [],
    now: formatRfc3339Millis(ctx.now),
    kind,
    ...(typeof params.team === "string" ? { team: params.team } : {}),
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
  if (op.kind === "invite.accept") id = ctx.rows.get<{ invite_id: string }>(TABLE_INVHASH, op.token_hash)?.row.invite_id
  if (id === undefined || head.invites?.some((invite) => invite.id === id)) return undefined
  return ctx.rows.get<Invite>(TABLE_INV, id)?.row
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

export const makeConversationDomain = (options: ConversationDomainOptions = {}): Domain<ConversationState, ConversationParams> => ({
  initial: () => null,
  reduce: (state, op, params, ctx) => {
    const actor = actorOf(ctx.principal)
    if (!actor) return refuse("forbidden")
    if (Object.hasOwn(CREATE_KINDS, op)) return reduceCreate(state, op, params, ctx, actor)
    if (!state) return refuse("unknown_conversation")
    // Params never name the actor or the op kind.
    const { actor: _actor, kind: _kind, secret, ...rest } = params as Record<string, unknown>
    let coreOp = { ...rest, kind: op } as unknown as Op
    if (op === "invite.accept") {
      // The secret is hashed here, so a token hash seen in an event cannot accept.
      if (typeof secret !== "string") return refuse("unknown_invite")
      const display = ctx.principal.display_name ?? (typeof rest.display_name === "string" ? rest.display_name : "")
      coreOp = { kind: "invite.accept", token_hash: hashInviteSecret(secret), display_name: display }
    }
    const loaded = loadInvite(state, ctx, coreOp)
    const head: ConversationHead = loaded ? { ...state, invites: [...(state.invites ?? []), loaded] } : state
    const messageId = targetMessageId(coreOp)
    const replyId = coreOp.kind === "message.send" ? coreOp.reply_to?.message_id : undefined
    const window = (head.settings?.agent_budget.turns ?? BUDGET_WINDOW - 1) + 1
    const recent = coreOp.kind === "message.send" ? ctx.rows.range<Message>(TABLE_MSG, { limit: window, desc: true }).map((row) => row.row) : undefined
    if (coreOp.kind === "message.send" && typeof coreOp.client_msg_id === "string" && ctx.rows.get(TABLE_MSGKEY, coreOp.client_msg_id)) {
      return refuse("idempotency_conflict")
    }
    const request: OpRequest = {
      actor,
      // The engine's ledger owns idempotency; `msgkey` keeps client_msg_id unique.
      idempotency_key: coreOp.kind === "message.send" ? coreOp.client_msg_id : "",
      op: coreOp,
      now: formatRfc3339Millis(ctx.now),
      new_message_id: coreOp.kind === "message.send" ? ctx.newId("msg") : "",
      target: messageId === undefined ? null : (ctx.rows.get<Message>(TABLE_MSG, messageId)?.row ?? null),
      reply_target: replyId === undefined ? null : (ctx.rows.get<Message>(TABLE_MSG, replyId)?.row ?? null),
      last_message: recent?.[0] ?? ctx.rows.range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row ?? null,
      recent: recent ?? null,
      actor_contacts: op === "invite.accept" && options.contactIdsFor ? options.contactIdsFor(ctx.principal) : null
    }
    const result = apply(head, request)
    if (!result.ok) return refuse(result.code)
    const { commit } = result
    const writes: Array<RowWrite> = []
    if (commit.message) {
      writes.push({ table: TABLE_MSG, op: "upsert", key: commit.message.id, n: commit.message.seq, row: commit.message })
      if (coreOp.kind === "message.send") writes.push({ table: TABLE_MSGKEY, op: "upsert", key: commit.message.client_msg_id, n: null, row: { message_id: commit.message.id } })
    }
    writes.push(...inviteWrites(head.invites ?? [], commit.head.invites ?? []))
    const next: ConversationHead = commit.head.invites ? { ...commit.head, invites: commit.head.invites.filter(isOpen) } : commit.head
    return {
      ok: true,
      state: next,
      value: { rev: commit.head.rev, ...(commit.message ? { seq: commit.message.seq, message_id: commit.message.id } : {}), change: commit.change },
      writes,
      outbox: commitOutbox(head, request, commit)
    }
  }
})

/** The domain without verified-address binding (tests, self-hosted without the contact key). */
export const conversationDomain = makeConversationDomain()
