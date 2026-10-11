import { previewAttachmentsOf, type PreviewAttachments } from "./attachments.ts"
import type { Commit, OpRequest } from "./request.ts"
import type { ConversationHead, ConversationKind, Message, Participant } from "./types.ts"
import { currentParticipants, findParticipant, utf8Bytes } from "./validate.ts"

/**
 * The fan-out intent of a commit (home-messaging.md section 5), as data: who
 * gets an inbox bump, which chiefs wake, the search projection, and invite
 * deliveries. Pure: the host turns it into outbox items (outbox.ts).
 */

export const PREVIEW_CHARS = 240
export const SEARCH_BODY_BYTES = 16 * 1024

/** Params of `inbox.bump` on the user's UserDO. */
export interface InboxBump {
  readonly user: string
  readonly conversation: string
  readonly rev: number
  readonly kind: ConversationKind
  readonly title: string
  readonly last_seq: number
  readonly last_at: string
  readonly preview: string
  /** The last message's attachments ({kind, count}); clients localize. Absent when it has none. */
  readonly preview_attachments?: PreviewAttachments
  /** Absent when the owner cannot derive it from the counts the host passed. */
  readonly unread?: number
  readonly mentions?: number
  readonly dm_peer?: string
  /** The user left or was removed in this commit. */
  readonly removed?: boolean
  /**
   * Push facts of the last message (`last_seq`), for the UserDO push decision. Every bump of
   * the conversation describes the same last message, so a coalesced bump keeps them.
   */
  readonly last_author?: string
  readonly last_author_kind?: "human" | "agent"
  /**
   * The last message is an agent's approval request addressed to this user (the agent's
   * `owner_user`): it notifies even when the conversation is muted. Other members never get it.
   */
  readonly last_approval?: true
  /** The last message mentions this user. */
  readonly last_mention?: true
  /** This user's `joined_seq`: messages at or before it were history when the user joined. */
  readonly joined_seq?: number
}

export type WakeReason = "dm" | "mention" | "reply"

export interface ChiefWake {
  readonly agent: string
  readonly owner_user?: string
  readonly conversation: string
  readonly seq: number
  readonly reason: WakeReason
}

export interface SearchRow {
  readonly conversation_id: string
  readonly seq: number
  readonly message_id: string
  readonly author_id: string
  readonly author_kind: "human" | "agent"
  readonly created_at: string
  readonly edited_at?: string
  /** Text parts joined by newlines, truncated at SEARCH_BODY_BYTES. */
  readonly body: string
}

export type SearchIntent = { readonly op: "upsert"; readonly row: SearchRow } | { readonly op: "delete"; readonly conversation_id: string; readonly seq: number }

export interface DeliveryIntent {
  readonly invite: string
  readonly conversation: string
  readonly address: string
  readonly channel: "email" | "sms"
  readonly locale: string
  readonly copy_variant: string
  readonly invited_by: string
}

export interface FanOut {
  readonly bumps: ReadonlyArray<InboxBump>
  readonly wakes: ReadonlyArray<ChiefWake>
  readonly search: ReadonlyArray<SearchIntent>
  readonly deliveries: ReadonlyArray<DeliveryIntent>
}

/** Unread and mention counts of one user before the commit (the host's fold of read cursors). */
export interface UnreadCounts {
  readonly unread: number
  readonly mentions: number
}

export interface FanOutInput {
  readonly before: ConversationHead
  readonly request: OpRequest
  readonly commit: Commit
  /** Counts per user before this commit, when the host has them. */
  readonly counts?: Readonly<Record<string, UnreadCounts>>
}

const textOf = (message: Message): string =>
  message.parts.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n")

/** Cuts `text` to at most `maxBytes` UTF-8 bytes on a code point boundary. */
export const truncateUtf8 = (text: string, maxBytes: number): string => {
  if (utf8Bytes(text) <= maxBytes) return text
  let out = ""
  let bytes = 0
  for (const char of text) {
    const size = utf8Bytes(char)
    if (bytes + size > maxBytes) break
    out += char
    bytes += size
  }
  return out
}

/** An `approval` part (home.md section 5). Read structurally: the part type is not in the conversation vocabulary yet. */
export const hasApprovalPart = (message: Message): boolean => message.parts.some((part) => (part as { readonly type: string }).type === "approval")

export const mentionsOf = (message: Message): ReadonlySet<string> =>
  new Set(message.parts.flatMap((part) => (part.type === "text" ? (part.runs ?? []).flatMap((run) => (run.mention ? [run.mention] : [])) : [])))

/** `Author: text`, at most PREVIEW_CHARS characters; empty for a retracted or text-less message. */
export const previewOf = (head: ConversationHead, message: Message | null | undefined): string => {
  if (!message || message.retracted_at !== undefined) return ""
  const text = textOf(message).replace(/\s+/gu, " ").trim()
  if (text === "") return ""
  const author = findParticipant(head, message.author)?.display_name ?? message.author
  return [...`${author}: ${text}`].slice(0, PREVIEW_CHARS).join("")
}

export const searchIntent = (head: ConversationHead, message: Message): SearchIntent => {
  const body = message.retracted_at === undefined ? truncateUtf8(textOf(message), SEARCH_BODY_BYTES) : ""
  if (body === "") return { op: "delete", conversation_id: message.conversation, seq: message.seq }
  const author = findParticipant(head, message.author)
  return {
    op: "upsert",
    row: {
      conversation_id: message.conversation,
      seq: message.seq,
      message_id: message.id,
      author_id: message.author,
      author_kind: author?.kind === "agent" ? "agent" : "human",
      created_at: message.created_at,
      ...(message.edited_at === undefined ? {} : { edited_at: message.edited_at }),
      body
    }
  }
}

/**
 * Wake rules (home.md section 5): with one human and one agent, the chief
 * wakes on every human message (`dm`); otherwise only on a mention or a reply
 * to its own message. `wake_policy` "mentions" drops the one-to-one rule, "all"
 * wakes every chief on every human message.
 */
export const wakesFor = (head: ConversationHead, message: Message, replyTarget: Message | null | undefined): ReadonlyArray<ChiefWake> => {
  const current = currentParticipants(head)
  const humans = current.filter((participant) => participant.kind === "human")
  const agents = current.filter((participant) => participant.kind === "agent")
  const fromHuman = findParticipant(head, message.author)?.kind === "human"
  const policy = head.settings?.wake_policy ?? "auto"
  const oneToOne = humans.length === 1 && agents.length === 1
  const mentioned = mentionsOf(message)
  const repliedTo = message.reply_to && replyTarget?.id === message.reply_to.message_id ? replyTarget.author : undefined
  const wakes: Array<ChiefWake> = []
  for (const chief of agents) {
    if (chief.agent_class !== "mux" || chief.id === message.author) continue
    let reason: WakeReason | undefined
    if (mentioned.has(chief.id)) reason = "mention"
    else if (repliedTo === chief.id) reason = "reply"
    else if (fromHuman && (policy === "all" || (policy === "auto" && oneToOne))) reason = "dm"
    if (reason) {
      wakes.push({ agent: chief.id, ...(chief.owner_user ? { owner_user: chief.owner_user } : {}), conversation: head.id, seq: message.seq, reason })
    }
  }
  return wakes
}

const dmPeer = (head: ConversationHead, user: string): string | undefined =>
  head.kind === "dm" ? head.participants.find((participant) => participant.id !== user)?.id : undefined

/** Commits that change what a conversation row in the inbox shows, for everyone. */
const ROW_CHANGING = new Set([
  "message.send",
  "message.retract",
  "title.set",
  "participants.add",
  "participants.remove",
  "invite.create",
  "invite.revoke",
  "invite.accept",
  "invite.approve_join"
])

/** The fan-out intent of one commit. */
export const fanOut = ({ before, request, commit, counts }: FanOutInput): FanOut => {
  const head = commit.head
  const op = request.op
  const message = commit.message
  const isLast = message !== undefined && message.seq === head.last_seq
  const lastMessage = isLast ? message : request.last_message?.seq === head.last_seq ? request.last_message : undefined
  const lastAt = lastMessage?.created_at ?? head.created_at
  const preview = previewOf(head, lastMessage)
  const previewAttachments = lastMessage && lastMessage.retracted_at === undefined ? previewAttachmentsOf(lastMessage) : undefined
  const humanIds = (participants: ReadonlyArray<Participant>) =>
    participants.filter((participant) => participant.kind === "human" && participant.left_at === undefined).map((participant) => participant.id)
  const nowHumans = humanIds(head.participants)
  const removed = humanIds(before.participants).filter((id) => !nowHumans.includes(id))

  let recipients: ReadonlyArray<string> = []
  if (ROW_CHANGING.has(op.kind)) recipients = nowHumans
  else if (op.kind === "message.edit" && message) {
    // An edit bumps when it changes the visible preview or anyone's mention count.
    const old = request.target
    const mentionChange = old ? !sameSet(mentionsOf(old), mentionsOf(message)) : false
    if (isLast || mentionChange) recipients = nowHumans
  } else if (op.kind === "read_cursor.set" && nowHumans.includes(request.actor)) recipients = [request.actor]

  const countFor = (user: string): UnreadCounts | undefined => {
    if (op.kind === "read_cursor.set" && op.seq === head.last_seq) return { unread: 0, mentions: 0 }
    const prior = counts?.[user]
    if (!prior || !message) return prior
    const cursor = head.read_cursors[user] ?? 0
    const unseen = message.author !== user && message.seq > cursor
    if (op.kind === "message.send") {
      return unseen ? { unread: prior.unread + 1, mentions: prior.mentions + (mentionsOf(message).has(user) ? 1 : 0) } : prior
    }
    if (op.kind === "message.retract") {
      const old = request.target
      const wasMention = old ? mentionsOf(old).has(user) : false
      return unseen ? { unread: Math.max(0, prior.unread - 1), mentions: Math.max(0, prior.mentions - (wasMention ? 1 : 0)) } : prior
    }
    if (op.kind === "message.edit" && request.target) {
      const delta = (mentionsOf(message).has(user) ? 1 : 0) - (mentionsOf(request.target).has(user) ? 1 : 0)
      return unseen ? { unread: prior.unread, mentions: Math.max(0, prior.mentions + delta) } : prior
    }
    return prior
  }

  const row = (user: string, isRemoved: boolean): InboxBump => {
    const count = isRemoved ? undefined : countFor(user)
    const peer = dmPeer(head, user)
    const author = lastMessage && lastMessage.retracted_at === undefined ? findParticipant(head, lastMessage.author) : undefined
    const joined = findParticipant(head, user)?.joined_seq
    return {
      user,
      conversation: head.id,
      rev: head.rev,
      kind: head.kind ?? "group",
      title: head.title,
      last_seq: head.last_seq,
      last_at: lastAt,
      preview,
      ...(previewAttachments ? { preview_attachments: previewAttachments } : {}),
      ...(count ? { unread: count.unread, mentions: count.mentions } : {}),
      ...(peer ? { dm_peer: peer } : {}),
      ...(isRemoved ? { removed: true } : {}),
      ...(author && lastMessage ? { last_author: author.id, last_author_kind: author.kind === "agent" ? ("agent" as const) : ("human" as const) } : {}),
      // Only an agent asks for approval, and only its owner can decide it (home.md section 5).
      ...(author?.kind === "agent" && author.owner_user === user && lastMessage && hasApprovalPart(lastMessage) ? { last_approval: true as const } : {}),
      ...(author && lastMessage && mentionsOf(lastMessage).has(user) ? { last_mention: true as const } : {}),
      ...(joined === undefined ? {} : { joined_seq: joined })
    }
  }
  const bumps = [...recipients.map((user) => row(user, false)), ...(ROW_CHANGING.has(op.kind) ? removed.map((user) => row(user, true)) : [])]

  const wakes = op.kind === "message.send" && message ? wakesFor(head, message, request.reply_target) : []
  const search =
    message && (op.kind === "message.send" || op.kind === "message.edit" || op.kind === "message.retract")
      ? [searchIntent(head, message)].filter((intent) => !(op.kind === "message.send" && intent.op === "delete"))
      : []
  const deliveries: Array<DeliveryIntent> = []
  if (op.kind === "invite.create") {
    const invite = head.invites?.find((candidate) => candidate.id === op.invite_id)
    if (invite) {
      deliveries.push({
        invite: invite.id,
        conversation: head.id,
        address: invite.address,
        channel: invite.channel,
        locale: invite.locale,
        copy_variant: invite.copy_variant,
        invited_by: invite.invited_by
      })
    }
  }
  return { bumps, wakes, search, deliveries }
}

const sameSet = (a: ReadonlySet<string>, b: ReadonlySet<string>): boolean => a.size === b.size && [...a].every((value) => b.has(value))
