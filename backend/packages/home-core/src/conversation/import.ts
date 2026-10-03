import { summary } from "./create.ts"
import type { OutboxItem, ReduceContext, ReduceResult, RowWrite } from "./engine-types.ts"
import { rowsOf } from "./engine-types.ts"
import { searchIntent, type FanOut } from "./fanout.ts"
import { formatRfc3339Millis, importConversationId, parseRfc3339Millis, validToken } from "./ids.ts"
import { fanOutItems, projectionItems } from "./outbox.ts"
import { stampParticipant, type ParticipantPolicy } from "./policy.ts"
import { RejectError } from "./reject.ts"
import { DEFAULT_SETTINGS, MAX_PARTICIPANTS, type ConversationHead, type ImportSource, type Message, type Participant, type Reaction } from "./types.ts"
import { findParticipant, hasText, reactionEquals, validateParticipant, validateParts, validateReaction, validateTitle } from "./validate.ts"

/**
 * `conversation.import` and `conversation.import.commit` (chief-mac.md P1,
 * `conversation.promote`): a Mac copies a local conversation into a new
 * ConversationDO. The first call creates the head in state `importing` with
 * the first batch; later calls continue the dense seq (`after_seq`); commit
 * opens the conversation for normal ops (`apply` refuses every other op
 * before that). Only the promoting user and agents that user owns may be
 * participants (a local conversation has no other humans), so an import
 * cannot add anyone without consent. Messages keep their ids, authors, times,
 * edits, retractions and reactions; each is validated like message.send.
 * Outbox: search rows per batch; inbox bumps only at commit; no chief wakes.
 */
export const MAX_IMPORT_BATCH = 500
/** Serialized size cap of one batch (engine event and ledger rows hold the params). */
export const MAX_IMPORT_BATCH_BYTES = 1024 * 1024
/** Allowed clock skew for imported times (they may not be in the future beyond it). */
const SKEW_MS = 5 * 60_000
export const IMPORT_OPS = new Set(["conversation.import", "conversation.import.commit"])

type Params = Readonly<Record<string, unknown>>
type Result = ReduceResult<ConversationHead | null>
const refuse = (code: string): Result => ({ ok: false, code, message: code })
const bad = (): never => {
  throw new RejectError("invalid_import")
}
const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const rfc = (v: unknown): string => (typeof v === "string" && parseRfc3339Millis(v) !== null ? v : bad())

const parseSource = (v: unknown): ImportSource | null => {
  if (!isObj(v) || v.kind !== "mac" || typeof v.host !== "string" || typeof v.local_id !== "string") return null
  if (!validToken(v.host) || !validToken(v.local_id)) return null
  return { kind: "mac", host: v.host, local_id: v.local_id }
}

/** Validates one imported message against the head (participants) and its expected seq. */
const importMessage = (head: ConversationHead, raw: unknown, seq: number, previous: Message | null, findById: (id: string) => Message | undefined, nowMs: number): Message => {
  if (!isObj(raw)) return bad()
  const { id, client_msg_id, author, parts, created_at } = raw
  if (raw.seq !== seq || typeof id !== "string" || !/^msg_[A-Za-z0-9]{1,40}$/.test(id)) return bad()
  if (typeof client_msg_id !== "string" || !validToken(client_msg_id)) return bad()
  if (typeof author !== "string" || !findParticipant(head, author) || findParticipant(head, author)!.kind === "address") return bad()
  // Times: not before the previous message, not in the future, edits and reactions after creation.
  const createdAt = rfc(created_at)
  const createdMs = parseRfc3339Millis(createdAt)!
  if ((previous && createdMs < parseRfc3339Millis(previous.created_at)!) || createdMs > nowMs + SKEW_MS) return bad()
  const notBefore = (v: unknown) => {
    const t = rfc(v)
    if (parseRfc3339Millis(t)! < createdMs || parseRfc3339Millis(t)! > nowMs + SKEW_MS) bad()
    return t
  }
  const retracted = raw.retracted_at === undefined ? undefined : notBefore(raw.retracted_at)
  const checkedParts = retracted !== undefined && Array.isArray(parts) && parts.length === 0 ? [] : validateParts(parts)
  const reactions: Array<Reaction> = []
  for (const r of Array.isArray(raw.reactions) ? raw.reactions : raw.reactions === undefined ? [] : bad()) {
    if (!isObj(r) || typeof r.author !== "string" || !findParticipant(head, r.author)) return bad()
    const index = r.part_index
    if (!Number.isInteger(index) || (index as number) < 0 || (index as number) >= checkedParts.length) return bad()
    const kind = validateReaction(r.kind)
    if (reactions.some((x) => x.author === r.author && x.part_index === index && reactionEquals(x.kind, kind))) return bad()
    reactions.push({ author: r.author, part_index: index as number, kind, at: notBefore(r.at) })
  }
  const reply = raw.reply_to
  if (reply !== undefined) {
    // As message.send: the target is an earlier message of this conversation and the part exists.
    if (!isObj(reply) || typeof reply.message_id !== "string" || !Number.isInteger(reply.part_index)) return bad()
    const target = findById(reply.message_id)
    if (!target || target.seq >= seq || (reply.part_index as number) < 0 || (reply.part_index as number) >= target.parts.length) return bad()
  }
  return {
    id,
    conversation: head.id,
    seq,
    client_msg_id,
    author,
    parts: checkedParts,
    ...(reply === undefined ? {} : { reply_to: { message_id: reply.message_id as string, part_index: reply.part_index as number } }),
    created_at: createdAt,
    ...(raw.edited_at === undefined ? {} : { edited_at: notBefore(raw.edited_at) }),
    ...(retracted === undefined ? {} : { retracted_at: retracted }),
    reactions
  }
}

/** Appends a batch: dense seq, unique ids, loop-guard counters updated as `apply` would. */
const appendBatch = (head: ConversationHead, rawMessages: unknown, ctx: ReduceContext): { head: ConversationHead; messages: Array<Message>; writes: Array<RowWrite> } => {
  if (!Array.isArray(rawMessages) || rawMessages.length > MAX_IMPORT_BATCH) return bad()
  if (Buffer.byteLength(JSON.stringify(rawMessages), "utf8") > MAX_IMPORT_BATCH_BYTES) return bad()
  const rows = rowsOf(ctx)
  let previous: Message | null = head.last_seq > 0 ? (rows.range<Message>("msg", { limit: 1, desc: true })[0]?.row ?? null) : null
  let next = head
  const messages: Array<Message> = []
  const writes: Array<RowWrite> = []
  for (const raw of rawMessages) {
    const findById = (id: string) => messages.find((m) => m.id === id) ?? rows.get<Message>("msg", id)?.row
    const message = importMessage(next, raw, next.last_seq + 1, previous, findById, ctx.now)
    previous = message
    const key = `${message.author}:${message.client_msg_id}`
    if (rows.get("msg", message.id) || rows.get("msgkey", key) || messages.some((m) => m.id === message.id || `${m.author}:${m.client_msg_id}` === key)) return bad()
    const agent = findParticipant(next, message.author)?.kind === "agent"
    const text = hasText(message.parts) || message.retracted_at !== undefined
    next = {
      ...next,
      last_seq: message.seq,
      updated_at: message.created_at,
      ...(text ? (agent ? { agent_text_streak: (next.agent_text_streak ?? 0) + 1, last_agent_text_at: message.created_at } : { agent_text_streak: 0 }) : {})
    }
    messages.push(message)
    writes.push({ table: "msg", op: "upsert", key: message.id, n: message.seq, row: message }, { table: "msgkey", op: "upsert", key, n: null, row: { message_id: message.id } })
  }
  return { head: next, messages, writes }
}

const searchItems = (before: ConversationHead | null, head: ConversationHead, messages: ReadonlyArray<Message>, now: string): Array<OutboxItem> => {
  const fan: FanOut = { bumps: [], wakes: [], search: messages.map((m) => searchIntent(head, m)), deliveries: [] }
  return projectionItems(before, { head, change: { kind: "conversation", conversation: summary(head, null) } }, fan, now, head.updated_at)
}

export const reduceImport = (state: ConversationHead | null, op: string, params: Params, ctx: ReduceContext, actor: string, policy: ParticipantPolicy): Result => {
  // Only the promoting user, from their own session or app install.
  if (!actor.startsWith("user_") || (ctx.principal.kind !== "session" && ctx.principal.kind !== "install") || ctx.principal.agent) return refuse("forbidden")
  const now = formatRfc3339Millis(ctx.now)
  try {
    if (op === "conversation.import.commit") {
      if (!state || state.import?.by !== actor) return refuse(state ? "forbidden" : "unknown_conversation")
      if (state.state !== "importing") return { ok: true, state, value: { conversation: summary(state, null) }, changed: false }
      if (params.last_seq !== state.last_seq) return refuse("import_out_of_order")
      const cursors = Object.fromEntries(Object.entries(state.read_cursors).map(([p, seq]) => [p, Math.min(seq, state.last_seq)]))
      const head: ConversationHead = { ...state, state: "active", read_cursors: cursors, rev: state.rev + 1 }
      const last = rowsOf(ctx).range<Message>("msg", { limit: 1, desc: true })[0]?.row ?? null
      const fan: FanOut = {
        bumps: head.participants
          .filter((p) => p.kind === "human")
          .map((p) => ({
            user: p.id,
            conversation: head.id,
            rev: head.rev,
            kind: head.kind ?? "group",
            title: head.title,
            last_seq: head.last_seq,
            last_at: last?.created_at ?? head.created_at,
            preview: "",
            unread: Math.max(0, head.last_seq - (cursors[p.id] ?? head.last_seq)),
            mentions: 0
          })),
        wakes: [],
        search: [],
        deliveries: []
      }
      const outbox = [...fanOutItems(fan, undefined, head.kind), ...searchItems(state, head, [], now)]
      return { ok: true, state: head, value: { conversation: summary(head, last) }, outbox }
    }
    const source = parseSource(params.source)
    if (state && params.after_seq === undefined) {
      // A repeated create: same source is a no-op, anything else is a different conversation.
      const same = source && state.import && state.import.by === actor && state.import.host === source.host && state.import.local_id === source.local_id
      return same ? { ok: true, state, value: { last_seq: state.last_seq, state: state.state }, changed: false } : refuse("conversation_exists")
    }
    if (state) {
      if (state.import?.by !== actor) return refuse("forbidden")
      if (state.state !== "importing") return refuse("conversation_exists")
      if (params.after_seq !== state.last_seq) return refuse("import_out_of_order")
      const batch = appendBatch({ ...state, rev: state.rev + 1 }, params.messages, ctx)
      return { ok: true, state: batch.head, value: { last_seq: batch.head.last_seq }, writes: batch.writes, outbox: searchItems(state, batch.head, batch.messages, now) }
    }
    // First call: create the head in `importing`.
    if (typeof params.id !== "string" || !source || (params.kind !== "group" && params.kind !== "chief")) return bad()
    // The id is derived from the importer and the source, so an import can only create its own object.
    if (params.id !== importConversationId(actor, source.host, source.local_id)) return refuse("invalid_conversation_id")
    const raw = params.participants
    if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_PARTICIPANTS) return bad()
    // Only the importer as a human, and only agents the reach policy says the importer owns;
    // owner_user and display names come from the policy, never from the params.
    const participants: Array<Participant> = []
    for (const rawParticipant of raw) {
      const p = validateParticipant(rawParticipant, true)
      if (p.kind === "address" || (p.kind === "human" && p.id !== actor)) return refuse("forbidden")
      const decision = policy(ctx.principal, p, null)
      if (!decision.ok) return refuse(decision.code)
      const stamped = stampParticipant(p, decision)
      if (stamped.kind === "agent" && stamped.owner_user !== actor) return refuse("forbidden")
      participants.push(stamped)
    }
    // Same shape as conversation.create: a chief conversation is the owner and one of their mux agents.
    if (params.kind === "chief") {
      const agents = participants.filter((p) => p.kind === "agent")
      if (participants.length !== 2 || agents.length !== 1 || agents[0]!.agent_class !== "mux") return refuse("invalid_participant")
    }
    if (!participants.some((p) => p.id === actor) || new Set(participants.map((p) => p.id)).size !== participants.length) return bad()
    const title = params.title === undefined ? "" : params.title
    if (title !== "") validateTitle(title)
    const cursorsIn = isObj(params.read_cursors) ? params.read_cursors : params.read_cursors === undefined ? {} : bad()
    const read_cursors: Record<string, number> = {}
    for (const [p, seq] of Object.entries(cursorsIn)) {
      if (!participants.some((x) => x.id === p && x.kind === "human") || !Number.isInteger(seq) || (seq as number) < 0) return bad()
      read_cursors[p] = seq as number
    }
    const base: ConversationHead = {
      id: params.id,
      title: title as string,
      participants: participants.map((p) => ({ ...p, role: p.id === actor ? "owner" : "member", joined_seq: 0, added_by: actor })),
      last_seq: 0,
      rev: 1,
      created_at: now,
      updated_at: now,
      read_cursors,
      kind: params.kind,
      created_by: actor,
      state: "importing",
      settings: DEFAULT_SETTINGS,
      invites: [],
      agent_text_streak: 0,
      import: { ...source, by: actor }
    }
    const batch = appendBatch(base, params.messages, ctx)
    return { ok: true, state: batch.head, value: { last_seq: batch.head.last_seq }, writes: batch.writes, outbox: searchItems(null, batch.head, batch.messages, now) }
  } catch (error) {
    if (error instanceof RejectError) return refuse(error.code)
    throw error
  }
}
