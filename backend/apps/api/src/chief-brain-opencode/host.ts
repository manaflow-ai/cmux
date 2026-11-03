import type { Env } from "../env.ts"
import type { Principal } from "@cmux/ownership"
import { brainModel } from "../model-gateway/routes.ts"
import { ackWake, chiefPrincipal, chiefRecord, postReply, readConversation } from "../chief-brain/brain-io.ts"
import { manageChiefs } from "../chief-brain/brain-chiefs.ts"
import type { BrainConfig } from "../chief-brain/brain-store.ts"
import { OWNER_APPROVAL_REQUIRED } from "../chief-brain/effect-policy.ts"
import { answerTarget, attachmentLine, inboxKind, sharedChief, type AttachmentMeta } from "../chief-brain/brain-text.ts"

/**
 * The Chief Protocol HOST services O's brain calls (brain -> host JSON-RPC requests), as the Chief
 * itself: the identity is the one OpencodeBrainDO derived from the container's token, never a field
 * of the request. Every call is one of the existing owner ops, so the reducer's rules (membership,
 * history floor, loop guard, idempotency) apply exactly as for the P brain.
 */
export interface Who {
  readonly agent: string
  readonly owner: string
  readonly config: BrainConfig
  readonly effects_authorized: boolean
  /** Brain impl version the brain reported in `initialize` (diagnostics only). */
  readonly impl?: string
}

export class HostRefused extends Error {
  constructor(readonly code: number, message: string) {
    super(message)
  }
}

const TEXT_PARTS = (parts: ReadonlyArray<{ type: string; text?: string; name?: string; url?: string }>) =>
  parts
    .map((p) => (p.type === "text" ? (p.text ?? "") : p.type === "attachment" ? attachmentLine(p as AttachmentMeta, false) : p.type === "link_preview" ? `[link: ${p.url ?? ""}]` : ""))
    .filter((t) => t.trim())
    .join("\n")

const str = (v: unknown, name: string): string => {
  if (typeof v !== "string" || v.length === 0 || v.length > 200) throw new HostRefused(-32602, `${name} is required`)
  return v
}

/**
 * Where a post that answers `message` without naming a thread goes (brain-text `answerTarget`, by the
 * conversation's own kind). `reply_to` alone, as before, when `message` is not among the newest messages.
 */
const postTarget = async (env: Env, conversation: string, principal: Principal, message: string): Promise<{ reply_to?: string; thread_root?: string }> => {
  // A failed read never costs the reply: it goes as before, `reply_to` alone.
  const view = await readConversation(env, conversation, principal, 100).catch(() => ({ refused: "owner.unreachable" }) as const)
  const answered = "refused" in view ? undefined : view.messages.find((m) => m.id === message)
  if (!answered || "refused" in view) return { reply_to: message }
  return answerTarget(inboxKind(view.head), answered, view.messages)
}

export const hostCall = async (env: Env, who: Who, method: string, params: Record<string, unknown>): Promise<unknown> => {
  const principal = chiefPrincipal(who.agent, who.owner)
  switch (method) {
    case "initialize": {
      const record = await chiefRecord(env, who.owner, who.agent)
      if (!record) throw new HostRefused(-32003, "the chief is archived or unknown")
      const c = who.config
      return {
        protocol: 1,
        chief: { id: who.agent, name: record.display_name, owner: who.owner, role: c.role, personality: c.personality, instructions: c.instructions, model: brainModel(c.model), effort: (c as { effort?: string }).effort ?? "low" },
        grants: [...(c.chiefs ? ["chiefs"] : [])],
        capabilities: { hands: false, chiefs: c.chiefs, model_gateway: true, credits: false, approvals: false, live: "chief-live-v1" }
      }
    }
    case "conversation/read": {
      const conversation = str(params.conversation, "conversation")
      const after = Number(params.after ?? 0) || 0
      const limit = Math.min(Math.max(Math.floor(Number(params.limit ?? 50)), 1), 100)
      const view = await readConversation(env, conversation, principal, limit + 20)
      if ("refused" in view) throw new HostRefused(-32003, view.refused)
      const names = new Map(view.head.participants.map((p) => [p.id, { name: p.display_name ?? p.id, kind: p.kind }]))
      const rows = view.messages
        .filter((m) => m.seq > after && m.retracted_at === undefined)
        .slice(-limit)
        .map((m) => ({
          id: m.id,
          seq: m.seq,
          author: m.author === who.agent ? { id: m.author, name: "you", kind: "self" } : { id: m.author, ...(names.get(m.author) ?? { name: m.author, kind: "person" }) },
          text: TEXT_PARTS(m.parts as ReadonlyArray<{ type: string; text?: string }>),
          ...(m.thread_root ? { thread_root: m.thread_root } : {})
        }))
        .filter((m) => m.text)
      return { conversation: { id: view.head.id, kind: view.head.kind ?? "group", ...(view.head.title ? { title: view.head.title } : {}), ...(sharedChief(view.head) ? { shared: true } : {}) }, messages: rows, cursor: Math.max(after, ...view.messages.map((m) => m.seq)) }
    }
    case "conversation/post": {
      const conversation = str(params.conversation, "conversation")
      const key = str(params.client_msg_id, "client_msg_id")
      const body = typeof params.body === "string" ? params.body : ""
      if (!body.trim()) throw new HostRefused(-32602, "body is empty")
      const run = typeof params.run === "string" ? params.run : undefined
      const replyTo = typeof params.reply_to === "string" ? params.reply_to : undefined
      // A reply names its thread: with `reply_to` alone it would show at the top level and its parent again above it.
      const target =
        typeof params.thread_root === "string" ? { ...(replyTo ? { reply_to: replyTo } : {}), thread_root: params.thread_root } : replyTo ? await postTarget(env, conversation, principal, replyTo) : {}
      const res = await postReply(env, principal, {
        conversation,
        text: body,
        run: { id: run ?? key, host: `cloud-chief-opencode:${who.agent}`, steps: 0 },
        ...target,
        key: `${who.agent}:${key}`
      })
      if (!res.ok) throw new HostRefused(res.code === "agent_rate" ? -32005 : -32003, `${res.code}: ${res.message}`)
      return { message: res.message }
    }
    case "chief/ack": {
      const conversation = typeof params.conversation === "string" ? params.conversation : null
      const cursor = Number(params.cursor ?? 0)
      if (conversation && cursor > 0) await ackWake(env, who.agent, principal, conversation, cursor)
      return {}
    }
    case "chiefs/manage": {
      if (!who.effects_authorized) return OWNER_APPROVAL_REQUIRED
      const { key, ...args } = params as { key?: string } & Record<string, unknown>
      return await manageChiefs(env, who.agent, who.owner, args as never, String(key ?? crypto.randomUUID())).catch((e: unknown) => (e instanceof Error ? e.message : String(e)))
    }
    case "hands/list":
      // HandDO (hq-1f B) is not in this deployment yet: no hand is paired.
      return []
    case "hand/call":
      throw new HostRefused(-32004, "no hand is paired with this Chief yet")
    default:
      throw new HostRefused(-32601, `unknown method ${method}`)
  }
}

export { brainModel }
