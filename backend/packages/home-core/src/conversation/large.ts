import type { RowReader, RowWrite } from "./engine-types.ts"
import { mentionsOf, previewOf, rowKind } from "./fanout.ts"
import type { OpRequest } from "./request.ts"
import { TABLE_MSG, UNREAD_RECOUNT_LIMIT } from "./tables.ts"
import type { ConversationHead, ConversationKind, Message, Op, Participant } from "./types.ts"

/**
 * The large tier of a cloud group (plans/cmux-next/home-dm-group-chats/DESIGN.md section 3).
 *
 * A group starts inline: every participant and read cursor lives in the head, as before. The
 * commit that takes it past INLINE_MAX current participants promotes it, once and for good:
 *
 * - `member` rows hold every participant record and its read cursor (key = participant id,
 *   n = join order, row = MemberRow). Departed records stay, so a rejoin keeps its name.
 * - The head keeps a bounded roster in `participants` (the owner, every current agent, and the
 *   earliest current humans up to ROSTER_HUMANS), `read_cursors` is empty, and `member_count`,
 *   `human_count` and `member_seq` count the rows.
 * - Each op runs on a *view head*: the roster plus the member rows the op names (the actor, the
 *   person it adds, removes or changes, the people a message mentions, the last author), with
 *   their cursors. The reducer (apply.ts) is the same for both tiers; `settle` writes back what
 *   changed and trims the head again. So a commit reads and writes O(named people), never O(N).
 * - Fan-out bumps only the people an op names (`focusOf`); everyone else pulls its row from the
 *   conversation (`inboxViewFor`) when it lists its inbox.
 */
export const TABLE_MEMBER = "member"
/** Current participants an inline head holds; one more promotes the group to the large tier. */
export const INLINE_MAX = 64
/** Humans the large-tier roster keeps (the owner and every current agent come on top). */
export const ROSTER_HUMANS = 16
/** Most current participants in a cloud group of either tier. */
export const MAX_GROUP_MEMBERS = 1_000_000

export interface MemberRow {
  readonly participant: Participant
  /** The participant's read cursor (seq); 0 when it never read. */
  readonly cursor: number
}

export const isLarge = (head: ConversationHead | null | undefined): boolean => head?.tier === "large"

/** Current participants of either tier. */
export const memberCount = (head: ConversationHead): number =>
  isLarge(head) ? (head.member_count ?? 0) : head.participants.filter((participant) => participant.left_at === undefined).length

/** A participant record (current or departed) from the head, or from the rows of a large group. */
export const recordOf = (head: ConversationHead, rows: RowReader, id: string): Participant | undefined => {
  const inline = head.participants.find((participant) => participant.id === id)
  if (inline || !isLarge(head)) return inline
  return rows.get<MemberRow>(TABLE_MEMBER, id)?.row.participant
}

/** A current participant of either tier (the ConversationDO's membership check). */
export const memberOf = (head: ConversationHead, rows: RowReader, id: string): Participant | undefined => {
  const record = recordOf(head, rows, id)
  return record && record.left_at === undefined ? record : undefined
}

/** A participant's read cursor of either tier. */
export const cursorOf = (head: ConversationHead, rows: RowReader, id: string): number =>
  isLarge(head) ? (rows.get<MemberRow>(TABLE_MEMBER, id)?.row.cursor ?? 0) : (head.read_cursors[id] ?? 0)

const participantArg = (op: Op): string | undefined => {
  const named = (op as { participant?: unknown }).participant
  if (typeof named === "string") return named
  if (typeof named === "object" && named !== null && typeof (named as { id?: unknown }).id === "string") return (named as { id: string }).id
  return undefined
}

const partsMentions = (parts: unknown): ReadonlyArray<string> =>
  Array.isArray(parts)
    ? parts.flatMap((part) => (part && typeof part === "object" && Array.isArray((part as { runs?: unknown }).runs) ? (part as { runs: Array<{ mention?: unknown }> }).runs : []))
        .flatMap((run) => (run && typeof run.mention === "string" ? [run.mention] : []))
    : []

/**
 * The people an op names, whose member rows its view head loads: the actor, the participant it
 * adds, removes or changes, a thread owner, the people its message mentions (also the edited
 * message's old mentions), the authors whose names a preview or an edit needs, and `extraIds`
 * (an invite's address, a revoked grant's maker).
 */
export const namedBy = (op: Op, actor: string, extra: ReadonlyArray<Message | null | undefined>, extraIds: ReadonlyArray<string | undefined> = []): ReadonlySet<string> => {
  const ids = new Set<string>([actor])
  for (const id of extraIds) if (id) ids.add(id)
  const target = participantArg(op)
  if (target) ids.add(target)
  const address = (op as { address?: unknown }).address
  if (typeof address === "string") ids.add(address)
  const owner = (op as { owner?: unknown }).owner
  if (op.kind === "thread.update" && typeof owner === "string" && owner !== "") ids.add(owner)
  for (const id of partsMentions((op as { parts?: unknown }).parts)) ids.add(id)
  for (const message of extra) {
    if (!message) continue
    ids.add(message.author)
    for (const id of mentionsOf(message)) ids.add(id)
  }
  return ids
}

/**
 * Who a large-group commit bumps: the actor, the participant the op adds or removes, and the
 * people the message mentions (an edit: the old and new mentions). Everyone else pulls.
 */
export const focusOf = (request: OpRequest, message: Message | undefined): ReadonlySet<string> => {
  const ids = new Set<string>([request.actor])
  const target = participantArg(request.op)
  if (target && (request.op.kind === "participants.add" || request.op.kind === "participants.remove")) ids.add(target)
  if (message && (request.op.kind === "message.send" || request.op.kind === "message.edit")) for (const id of mentionsOf(message)) ids.add(id)
  if (request.op.kind === "message.edit" && request.target) for (const id of mentionsOf(request.target)) ids.add(id)
  return ids
}

/** The head an op of a large group runs on: the roster plus the named member rows and their cursors. */
export const viewHead = (head: ConversationHead, rows: RowReader, ids: ReadonlySet<string>): ConversationHead => {
  if (!isLarge(head)) return head
  const loaded = new Map<string, MemberRow>()
  for (const id of ids) {
    const row = rows.get<MemberRow>(TABLE_MEMBER, id)?.row
    if (row) loaded.set(id, row)
  }
  const participants = head.participants.map((participant) => loaded.get(participant.id)?.participant ?? participant)
  for (const [id, row] of loaded) if (!participants.some((participant) => participant.id === id)) participants.push(row.participant)
  const read_cursors: Record<string, number> = {}
  for (const [id, row] of loaded) if (row.cursor > 0) read_cursors[id] = row.cursor
  return { ...head, participants, read_cursors }
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

/**
 * Writes back what a large-group commit changed in its view head (records and cursors), keeps the
 * counts, and trims the head to the roster again. `before` is the view head the op ran on.
 */
export const settle = (stored: ConversationHead, before: ConversationHead, after: ConversationHead, rows: RowReader): { head: ConversationHead; writes: Array<RowWrite> } => {
  const writes: Array<RowWrite> = []
  let memberCountNow = before.member_count ?? 0
  let humanCountNow = before.human_count ?? 0
  let seq = before.member_seq ?? 0
  for (const participant of after.participants) {
    const old = before.participants.find((candidate) => candidate.id === participant.id)
    const cursor = after.read_cursors[participant.id] ?? 0
    const oldCursor = before.read_cursors[participant.id] ?? 0
    if (old && same(old, participant) && cursor === oldCursor) continue
    const stored = rows.get<MemberRow>(TABLE_MEMBER, participant.id)
    const n = stored?.n ?? ++seq
    writes.push({ table: TABLE_MEMBER, op: "upsert", key: participant.id, n, row: { participant, cursor } satisfies MemberRow })
    const prior = stored?.row.participant ?? old
    const was = prior !== undefined && prior.left_at === undefined
    const is = participant.left_at === undefined
    if (was !== is) {
      memberCountNow += is ? 1 : -1
      if (participant.kind === "human") humanCountNow += is ? 1 : -1
    }
  }
  // A record dropped from the view (a departed address outside a dm) leaves the rows too.
  for (const old of before.participants) {
    if (after.participants.some((participant) => participant.id === old.id)) continue
    writes.push({ table: TABLE_MEMBER, op: "delete", key: old.id })
    if (old.left_at === undefined) {
      memberCountNow -= 1
      if (old.kind === "human") humanCountNow -= 1
    }
  }
  const roster = rosterOf(stored, after, rows, writes)
  const head: ConversationHead = {
    ...after,
    participants: roster,
    read_cursors: {},
    tier: "large",
    member_count: memberCountNow,
    human_count: humanCountNow,
    member_seq: seq,
    // No current human left archives the group, as an inline one (cloud.ts archiveIfEmpty).
    ...(humanCountNow <= 0 ? { state: "archived" as const } : {})
  }
  return { head, writes }
}

const keepInRoster = (participant: Participant, after: ConversationHead) =>
  participant.left_at === undefined && (participant.kind === "agent" || participant.role === "owner" || participant.id === after.created_by)

/** The roster after a commit: the stored one with changes applied, refilled from the rows. */
const rosterOf = (stored: ConversationHead, after: ConversationHead, rows: RowReader, writes: ReadonlyArray<RowWrite>): Array<Participant> => {
  const rosterIds = new Set(stored.participants.filter((participant) => !participant.left_at).map((participant) => participant.id))
  const current = (participant: Participant) => participant.left_at === undefined
  const byId = new Map(after.participants.map((participant) => [participant.id, participant]))
  const out: Array<Participant> = []
  // Kept: roster members still current (with their new record), and anyone the roster must hold.
  for (const participant of after.participants) {
    if (!current(participant)) continue
    if (rosterIds.has(participant.id) || keepInRoster(participant, after)) out.push(participant)
  }
  // Newcomers fill free human seats in join order.
  const humans = () => out.filter((participant) => participant.kind === "human").length
  for (const participant of after.participants) {
    if (humans() >= ROSTER_HUMANS) break
    if (current(participant) && participant.kind === "human" && !out.includes(participant)) out.push(participant)
  }
  // A seat freed by a departure refills from the earliest member rows (a bounded scan).
  if (humans() < ROSTER_HUMANS) {
    const written = new Map(writes.flatMap((w) => (w.table === TABLE_MEMBER && w.op === "upsert" ? [[w.key, (w.row as MemberRow).participant] as const] : [])))
    for (const { row } of rows.range<MemberRow>(TABLE_MEMBER, { limit: ROSTER_HUMANS * 4 })) {
      if (humans() >= ROSTER_HUMANS) break
      const participant = written.get(row.participant.id) ?? byId.get(row.participant.id) ?? row.participant
      if (current(participant) && participant.kind === "human" && !out.some((other) => other.id === participant.id)) out.push(participant)
    }
  }
  return out
}

/**
 * Promotes an inline group past INLINE_MAX to the large tier: every record (also departed ones)
 * and cursor becomes a member row, and the head keeps the roster. Runs once, in the commit that
 * crossed the line.
 */
export const promote = (head: ConversationHead): { head: ConversationHead; writes: Array<RowWrite> } => {
  const writes: Array<RowWrite> = []
  let seq = 0
  for (const participant of head.participants) {
    writes.push({ table: TABLE_MEMBER, op: "upsert", key: participant.id, n: ++seq, row: { participant, cursor: head.read_cursors[participant.id] ?? 0 } satisfies MemberRow })
  }
  const current = head.participants.filter((participant) => participant.left_at === undefined)
  const roster: Array<Participant> = []
  for (const participant of current) {
    const humansIn = roster.filter((other) => other.kind === "human").length
    if (participant.kind !== "human" || participant.role === "owner" || humansIn < ROSTER_HUMANS) roster.push(participant)
  }
  return {
    head: {
      ...head,
      participants: roster,
      read_cursors: {},
      tier: "large",
      member_count: current.length,
      human_count: current.filter((participant) => participant.kind === "human").length,
      member_seq: seq
    },
    writes
  }
}

/** Whether a commit takes an inline group past INLINE_MAX. */
export const needsPromotion = (head: ConversationHead): boolean =>
  head.kind === "group" && !isLarge(head) && head.participants.filter((participant) => participant.left_at === undefined).length > INLINE_MAX

/** One page of `conversation.members`: current participants in join order. */
export interface MembersPage {
  readonly members: ReadonlyArray<Participant>
  readonly member_count: number
  /** Pass as `after` for the next page; absent on the last page. */
  readonly next?: number
}

export const MEMBERS_PAGE_LIMIT = 1000

export const membersPage = (head: ConversationHead, rows: RowReader, query: { readonly after?: number; readonly limit?: number }): MembersPage => {
  const limit = Math.max(1, Math.min(query.limit ?? 200, MEMBERS_PAGE_LIMIT))
  if (!isLarge(head)) {
    const current = head.participants.filter((participant) => participant.left_at === undefined)
    const start = query.after ?? 0
    const members = current.slice(start, start + limit)
    return { members, member_count: current.length, ...(start + limit < current.length ? { next: start + limit } : {}) }
  }
  const members: Array<Participant> = []
  let after = query.after ?? 0
  let last = after
  // Departed rows are skipped; a window of only departed rows still advances the cursor.
  for (let window = 0; window < 8 && members.length < limit; window++) {
    const batch = rows.range<MemberRow>(TABLE_MEMBER, { after, limit: limit - members.length })
    if (batch.length === 0) {
      last = -1
      break
    }
    for (const { n, row } of batch) {
      last = n ?? last
      if (row.participant.left_at === undefined) members.push(row.participant)
    }
    after = last
  }
  const more = last >= 0 && rows.range<MemberRow>(TABLE_MEMBER, { after: last, limit: 1 }).length > 0
  return { members, member_count: head.member_count ?? members.length, ...(more ? { next: last } : {}) }
}

/** A member's inbox row, pulled from the conversation (large groups bump only named people). */
export interface InboxView {
  readonly conversation: string
  readonly kind: ConversationKind
  readonly title: string
  readonly rev: number
  readonly last_seq: number
  readonly last_at: string
  readonly preview: string
  readonly unread: number
  readonly mentions: number
  readonly member_count: number
}

/**
 * `user`'s inbox row computed from the conversation: title, last message, and unread and mention
 * counts after its cursor (and its join, with history_visible since_join), at most
 * UNREAD_RECOUNT_LIMIT messages read. Null when `user` is not a current participant.
 */
export const inboxViewFor = (head: ConversationHead, rows: RowReader, user: string): InboxView | null => {
  const me = memberOf(head, rows, user)
  if (!me) return null
  const floor = Math.max(cursorOf(head, rows, user), head.settings?.history_visible === "since_join" ? (me.joined_seq ?? 0) : 0)
  let unread = 0
  let mentions = 0
  for (const { row } of rows.range<Message>(TABLE_MSG, { after: floor, limit: UNREAD_RECOUNT_LIMIT })) {
    if (row.author === user || row.retracted_at !== undefined) continue
    unread += 1
    if (mentionsOf(row).has(user)) mentions += 1
  }
  const last = rows.range<Message>(TABLE_MSG, { limit: 1, desc: true })[0]?.row
  const author = last ? recordOf(head, rows, last.author) : undefined
  const named = author && !head.participants.some((participant) => participant.id === author.id) ? { ...head, participants: [...head.participants, author] } : head
  return {
    conversation: head.id,
    kind: rowKind(head, user),
    title: head.title,
    rev: head.rev,
    last_seq: head.last_seq,
    last_at: last?.created_at ?? head.created_at,
    preview: previewOf(named, last),
    unread,
    mentions,
    member_count: memberCount(head)
  }
}
