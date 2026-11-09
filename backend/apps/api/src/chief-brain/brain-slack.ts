import { conversation as homeConversation } from "@cmux/home-core"
import { formatSlackMessage, isOwnSlackMessage, postSlackMessage, slackEnabled, validSlackInbound, type SlackInbound } from "../chief-slack.ts"
import { sha256Hex } from "../ingress/verify.ts"
import type { ChiefBrainDO } from "./brain-do.ts"
import { declared } from "../do-stub.ts"

export interface SlackWake { readonly agent: string; readonly conversation: string; readonly inbound: SlackInbound }
export interface SlackOutbound { readonly root: string; readonly message: string; readonly text: string }

export const SLACK_SCHEMA = [
  `CREATE TABLE IF NOT EXISTS cb_slack_threads (slack_team TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, root TEXT UNIQUE NOT NULL, PRIMARY KEY (slack_team, channel, thread_ts))`,
  `CREATE TABLE IF NOT EXISTS cb_slack_sent (message TEXT PRIMARY KEY)`,
  `CREATE TABLE IF NOT EXISTS cb_slack_bot_messages (slack_team TEXT NOT NULL, channel TEXT NOT NULL, ts TEXT NOT NULL, PRIMARY KEY (slack_team, channel, ts))`
]

export async function slackInbound(b: ChiefBrainDO, w: SlackWake) {
  if (!slackEnabled(b.doEnv)) return { ok: false as const, code: "slack.disabled" }
  if (!validSlackInbound(w.inbound)) return { ok: false as const, code: "validation.invalid" }
  if (isOwnSlackMessage(w.inbound)) return { ok: true as const, ignored: true as const, queued: false }
  await b.lifecycle.start()
  if (b.sql.exec(`SELECT 1 FROM cb_slack_bot_messages WHERE slack_team = ? AND channel = ? AND ts = ?`, w.inbound.slackTeamId, w.inbound.channelId, w.inbound.ts).toArray().length) return { ok: true as const, ignored: true as const, queued: false }
  const a = await b.admitted(w.agent, w.inbound.ownerUserId, false)
  if (!a.ok) return { ok: false as const, code: `chief.${a.reason}` }
  const i = w.inbound
  // Reserve the root before the first cross-object call. Interleaved messages/replays use the same root.
  const proposedRoot = `msg_${(await sha256Hex(JSON.stringify([w.agent, w.conversation, i.slackTeamId, i.channelId, i.threadTs]))).slice(0, 32)}`
  b.sql.exec(`INSERT INTO cb_slack_threads (slack_team, channel, thread_ts, root) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`, i.slackTeamId, i.channelId, i.threadTs, proposedRoot)
  const root = b.sql.exec<{ root: string }>(`SELECT root FROM cb_slack_threads WHERE slack_team = ? AND channel = ? AND thread_ts = ?`, i.slackTeamId, i.channelId, i.threadTs).one().root
  const conversation = declared(b.doEnv.CONVERSATION_DO.get(b.doEnv.CONVERSATION_DO.idFromName(w.conversation)))
  const res = await conversation.slackMessage(w.conversation, { owner: i.ownerUserId, agent: w.agent, root, inbound: i })
  const frame = res.frames.find((f) => f.t === "result" || f.t === "reject")
  if (!frame || frame.t === "reject") return { ok: false as const, code: frame?.t === "reject" ? frame.code : "owner.unreachable" }
  const value = (frame as { value: { message_id: string; expired: true } | { message_id: string; seq: number; change: { message: homeConversation.Message & { slack: { isOwner: boolean; displayName: string } } } } }).value
  if ("expired" in value) return { ok: true as const, conversation: w.conversation, thread: root, queued: false }
  const committed = value.change.message
  const committedRoot = committed.thread_root ?? committed.id
  const authorized = committed.slack.isOwner
  const text = formatSlackMessage(committed)
  // Preserve provenance even if an ordinary wake already loaded this message as context.
  const fresh = b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, 'slack', ?, ?, ?, 1) ON CONFLICT (message) DO NOTHING RETURNING n`, value.message_id, w.conversation, value.seq, committedRoot, text, authorized ? 1 : 0).toArray()
  b.sql.exec(`UPDATE cb_inbox SET woke = 1, kind = 'slack', thread_root = ?, effect_authorized = ? WHERE message = ? AND state = 'queued'`, committedRoot, authorized ? 1 : 0, value.message_id)
  if (fresh.length && b.turnLive && b.turnId && b.turnConversation === w.conversation) await b.steerQueued(w.conversation)
  b.kick()
  return { ok: true as const, conversation: w.conversation, thread: committedRoot, queued: fresh.length > 0 }
}

/** Called after ConversationDO committed an owner/Chief reply. Claim before sending: no replay can resend it. */
export async function slackOutbound(b: ChiefBrainDO, reply: SlackOutbound): Promise<void> {
  if (!slackEnabled(b.doEnv)) return
  const link = b.sql.exec<{ slack_team: string; channel: string; thread_ts: string }>(`SELECT slack_team, channel, thread_ts FROM cb_slack_threads WHERE root = ?`, reply.root).toArray()[0]
  if (!link || !reply.text.trim()) return
  const fresh = b.sql.exec(`INSERT INTO cb_slack_sent (message) VALUES (?) ON CONFLICT DO NOTHING RETURNING message`, reply.message).toArray()
  if (!fresh.length) return
  b.doCtx.waitUntil(postSlackMessage(b.doEnv, { slackTeamId: link.slack_team, channelId: link.channel, threadTs: link.thread_ts, text: reply.text }).then((ts) => {
    if (ts) b.sql.exec(`INSERT INTO cb_slack_bot_messages (slack_team, channel, ts) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, link.slack_team, link.channel, ts)
  }))
}
