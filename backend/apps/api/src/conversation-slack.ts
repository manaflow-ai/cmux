import { conversation } from "@cmux/home-core"
import { createHash } from "node:crypto"
import type { Domain, OutboxItem, ReduceContext, ReduceResult, RowReader } from "@cmux/ownership"
import { validSlackInbound, type SlackInbound } from "./chief-slack.ts"

/** Trusted metadata on a Slack thread's root; ordinary conversation ops cannot set it. */
export interface SlackThread {
  readonly source: "slack"
  readonly slackTeamId: string
  readonly channelId: string
  readonly threadTs: string
  readonly channelName: string
  readonly permalink: string
  readonly chief: string
  readonly ownerUserId: string
}
export interface SlackMessageInput {
  readonly owner: string
  readonly agent: string
  readonly root: string
  readonly inbound: SlackInbound
}
type Head = conversation.ConversationState
type SlackMessage = conversation.Message & { readonly slack?: { readonly isOwner: boolean; readonly displayName: string } }
const fail = (code: string): ReduceResult<Head> => ({ ok: false, code, message: code })
export const slackDeliveryKey = (input: SlackMessageInput): string => `slack-delivery:${createHash("sha256").update(JSON.stringify(input)).digest("hex")}`
export const slackMessageKey = (w: SlackInbound): string => `slack:${createHash("sha256").update(JSON.stringify([w.slackTeamId, w.channelId, w.ts])).digest("hex")}`

export const slackThread = (message: conversation.Message | undefined): SlackThread | undefined => {
  const thread = message?.thread as (conversation.ThreadState & Partial<SlackThread>) | undefined
  return thread?.source === "slack" && typeof thread.chief === "string" && typeof thread.ownerUserId === "string" ? thread as SlackThread : undefined
}

/** Slack people are display participants, never cloud UserDOs or inbox recipients. */
const realRecipient = (item: OutboxItem) => !(item.target?.class === "UserDO" && item.target.name.startsWith("slack:"))

const receive = (state: Head, raw: unknown, ctx: ReduceContext): ReduceResult<Head> => {
  if (ctx.principal.kind !== "system" || ctx.principal.identity !== "system:slack") return fail("forbidden")
  const input = raw as Partial<SlackMessageInput> | null
  const w = input?.inbound
  if (!w || !input?.root || !/^msg_[A-Za-z0-9]{1,40}$/.test(input.root) || !validSlackInbound(w)) return fail("validation.invalid")
  if (!state || state.kind !== "chief" || w.ownerUserId !== input.owner || !state.participants.some((p) => p.id === input.owner && p.kind === "human" && p.left_at === undefined) || !state.participants.some((p) => p.id === input.agent && p.kind === "agent" && p.owner_user === input.owner && p.left_at === undefined)) return fail("forbidden")
  const author = `slack:${w.slackTeamId}:${w.slackUserId}`
  const key = slackMessageKey(w)
  // Slack timestamps identify messages within a workspace/channel, independently of the author.
  const messageKey = key
  const priorId = ctx.rows?.get<{ message_id: string }>(conversation.TABLE_MSGKEY, messageKey)?.row.message_id
  if (priorId) {
    const prior = ctx.rows?.get<conversation.Message>(conversation.TABLE_MSG, priorId)?.row
    // Retention keeps the tuple tombstone: a retry must not resurrect expired content.
    if (!prior) return { ok: true, state, value: { message_id: priorId, expired: true }, changed: false }
    return { ok: true, state, value: { message_id: priorId, seq: prior.seq, change: { kind: "message", message: prior } }, changed: false }
  }
  const root = ctx.rows?.get<conversation.Message>(conversation.TABLE_MSG, input.root)?.row
  const link = slackThread(root)
  if (root && (!link || link.slackTeamId !== w.slackTeamId || link.channelId !== w.channelId || link.threadTs !== w.threadTs || link.chief !== input.agent || link.ownerUserId !== input.owner)) return fail("invalid_thread_root")
  const participant: conversation.Participant = { id: author, kind: "human", display_name: conversation.safeDisplayName(w.slackUserName, "Slack member"), role: "member", joined_seq: state.last_seq, added_by: input.owner }
  const known = state.participants.find((p) => p.id === author)
  // A removed Slack participant stays removed until the owner restores access.
  if (known?.left_at !== undefined) return fail("not_participant")
  const head = { ...state, participants: known ? state.participants.map((p) => p.id === author ? { ...p, display_name: participant.display_name } : p) : [...state.participants, participant] }
  const request: conversation.OpRequest = {
    actor: author, idempotency_key: key,
    op: { kind: "message.send", client_msg_id: key, parts: [{ type: "text", text: w.text }], ...(root ? { thread_root: root.id } : {}) },
    now: conversation.formatRfc3339Millis(ctx.now), new_message_id: root ? ctx.newId("msg") : input.root,
    thread_target: root, last_message: ctx.rows?.range<conversation.Message>(conversation.TABLE_MSG, { limit: 1, desc: true })[0]?.row
  }
  const applied = conversation.apply(head, request)
  if (!applied.ok) return fail(applied.code)
  const metadata: SlackThread = { source: "slack", slackTeamId: w.slackTeamId, channelId: w.channelId, threadTs: w.threadTs, channelName: w.channelName || w.channelId, permalink: w.permalink, chief: input.agent!, ownerUserId: input.owner! }
  const message: SlackMessage = { ...applied.commit.message!, slack: { isOwner: w.isOwner, displayName: participant.display_name! }, ...(!root ? { thread: { title: `Slack · #${metadata.channelName.replace(/^#/, "")}`, ...metadata } } : {}) }
  const commit: conversation.Commit = { ...applied.commit, message, change: { kind: "message", message } }
  const outbox = conversation.commitOutbox(state, request, commit).filter((item) => item.kind !== "mux.wake" && realRecipient(item))
  return {
    ok: true, state: commit.head, value: { message_id: message.id, seq: message.seq, change: commit.change }, outbox,
    writes: [
      { table: conversation.TABLE_MSG, op: "upsert", key: message.id, n: message.seq, row: message },
      { table: conversation.TABLE_MSGKEY, op: "upsert", key: messageKey, n: null, row: { message_id: message.id } }
    ]
  }
}

/** Extend only the hosted owner: the public op catalog never exposes slack.message. */
export const withSlack = (domain: Domain<Head, conversation.ConversationParams>): Domain<Head, conversation.ConversationParams> => ({
  ...domain,
  reduce: (state, op, params, ctx) => {
    if (op === "slack.message") return receive(state, params, ctx)
    const result = domain.reduce(state, op, params, ctx)
    if (!result.ok) return result
    // Clearing a title/resolution must not remove the root's transport link.
    const root = op === "thread.update" && typeof params.root === "string" ? ctx.rows?.get<conversation.Message>(conversation.TABLE_MSG, params.root)?.row : undefined
    const link = slackThread(root)
    if (!link) return { ...result, outbox: result.outbox?.filter(realRecipient) }
    let changed: conversation.Message | undefined
    const writes = result.writes?.map((write) => {
      if (write.op !== "upsert" || write.table !== conversation.TABLE_MSG || write.key !== root?.id) return write
      const message = write.row as conversation.Message
      changed = { ...message, thread: { ...message.thread, ...link } }
      return { ...write, row: changed }
    })
    return { ...result, writes, outbox: result.outbox?.filter(realRecipient), ...(changed ? { value: { ...(result.value as object), change: { kind: "message", message: changed } } } : {}) }
  }
})

/** Select only committed Chief/owner text in a linked thread, including reply_to-only clients. */
export const slackOutbound = (rows: RowReader, message: conversation.Message, state: conversation.ConversationHead): { agent: string; root: string; message: string; text: string } | undefined => {
  let root: conversation.Message | undefined = message
  const visited = new Set<string>()
  while (root && !slackThread(root)) {
    if (visited.has(root.id)) return
    visited.add(root.id)
    const next: string | undefined = root.thread_root ?? root.reply_to?.message_id
    root = next ? rows.get<conversation.Message>(conversation.TABLE_MSG, next)?.row : undefined
  }
  const link = slackThread(root)
  if (!root || !link || (message.author !== link.chief && message.author !== link.ownerUserId)) return
  const text = message.parts.filter((p) => p.type === "text").map((p) => p.text).join("\n")
  if (!text.trim()) return
  const name = state.participants.find((p) => p.id === link.ownerUserId)?.display_name ?? "Owner"
  return { agent: link.chief, root: root.id, message: message.id, text: message.author === link.ownerUserId ? `${name}: ${text}` : text }
}
