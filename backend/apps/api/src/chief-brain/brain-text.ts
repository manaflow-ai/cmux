import type { conversation } from "@cmux/home-core"
import { NO_REPLY } from "./prompts.ts"

type Head = NonNullable<conversation.ConversationState>
type Message = conversation.Message

/** Words of a model reply or tool result, from pi-ai content parts. */
export const textParts = (content: ReadonlyArray<{ type: string; text?: string }>): string =>
  content
    .filter((p) => p.type === "text")
    .map((p) => p.text ?? "")
    .join("")

/**
 * After `reset()`, pi appends the new user entry first and its system entry (sections and tools)
 * at the first request, so the transcript reads [user, system, ...]. Moving the system entry to the
 * front gives tools, system, view, message: the system prefix caches across turns.
 */
export function systemFirst<M extends { role: string }>(messages: ReadonlyArray<M>): { messages: Array<M> } | undefined {
  const at = messages.findIndex((m) => m.role === "system")
  if (at <= 0) return undefined
  const out = [...messages]
  const [system] = out.splice(at, 1)
  return { messages: [system!, ...out] }
}

type ToolDecl = { readonly name: string; readonly description?: string; readonly parameters?: unknown }
type Transcript = { role: string; content?: unknown; toolsAdded?: ReadonlyArray<ToolDecl>; toolsRemoved?: ReadonlyArray<{ name: string }> }

/**
 * Thinking blocks the model made under another tools list, removed for this request. The model route checks
 * every replayed signed thinking block against the request's tools list (a changed list is a 400: "Invalid
 * signature in thinking block ... The tools list differs"), and the API allows dropping thinking from earlier
 * turns. The tools in force at each assistant message come from the transcript itself (system entries carry
 * toolsAdded / toolsRemoved), so the comparison is exact; only blocks made under a different list go. Text,
 * tool calls and tool results stay. The in-progress turn (after the last user message; tool results are their own
 * role) is never touched: its thinking is required with its tool calls, and its list cannot change mid-turn (a
 * mismatch there is counted in `openMismatch`). The fold matches the route while one tool name is redefined in
 * place (pi-ai then sends the folded list as `tools`); the Bedrock body drops the route's own block_binding, so
 * this client-side strip is what keeps a changed list valid there.
 */
export function stripStaleThinking<M extends Transcript>(messages: ReadonlyArray<M>): { messages: Array<M>; stripped: number; openMismatch: number } {
  const tools = new Map<string, string>()
  const keyOf = () => JSON.stringify([...tools])
  const keys: Array<string | null> = []
  for (const m of messages) {
    if (m.role === "system") {
      for (const t of m.toolsRemoved ?? []) tools.delete(t.name)
      for (const t of m.toolsAdded ?? []) tools.set(t.name, JSON.stringify([t.description ?? "", t.parameters ?? {}]))
    }
    keys.push(m.role === "assistant" ? keyOf() : null)
  }
  const now = keyOf()
  const open = messages.map((m) => m.role).lastIndexOf("user")
  let stripped = 0
  let openMismatch = 0
  const out = messages.map((m, i) => {
    if (m.role !== "assistant" || keys[i] === now || !Array.isArray(m.content)) return m
    if (i > open) return (openMismatch++, m)
    const kept = (m.content as Array<{ type: string }>).filter((b) => b.type !== "thinking" && b.type !== "redacted_thinking")
    if (kept.length === (m.content as Array<unknown>).length) return m
    stripped += (m.content as Array<unknown>).length - kept.length
    return { ...m, content: kept }
  })
  return { messages: out, stripped, openMismatch }
}

const nameOf = (head: Head, id: string) => head.participants.find((p) => p.id === id)?.display_name ?? id

/**
 * One conversation message as the Chief reads it: a header in brackets (conversation, kind, author,
 * thread), then the text, with mentions shown as @name and attachments as one line each. Empty
 * when the message carries nothing a model can read.
 */
export const formatMessage = (head: Head, m: Message): string => {
  const lines: Array<string> = []
  for (const part of m.parts) {
    if (part.type === "text") {
      let text = part.text
      // Mentions right to left so earlier offsets stay valid.
      for (const run of [...(part.runs ?? [])].sort((a, b) => b.start - a.start)) {
        if (run.mention) text = `${text.slice(0, run.start)}@${nameOf(head, run.mention)}${text.slice(run.start + run.length)}`
      }
      if (text.trim()) lines.push(text)
    } else if (part.type === "attachment") lines.push(`[attachment: ${(part as { name?: string }).name ?? "file"}]`)
    else if (part.type === "link_preview") lines.push(`[link: ${(part as { url?: string }).url ?? ""}]`)
  }
  if (lines.length === 0) return ""
  const kind = head.kind ?? "group"
  const where = head.title?.trim() ? head.title.trim() : kind
  const thread = m.thread_root ? " · in a thread" : ""
  return `[${where} · ${kind} · ${nameOf(head, m.author)}${thread}] ${lines.join("\n")}`
}

/**
 * Where the reply goes: in a channel or group, the thread of the message answered (its own thread,
 * or the thread it is in); in the chief's line or a DM, the main timeline unless that message was
 * already in a thread.
 */
export const replyTarget = (kind: string, message: string, threadRoot: string | null): { reply_to?: string; thread_root?: string } => {
  if (kind === "chief" || kind === "dm") return threadRoot ? { reply_to: message, thread_root: threadRoot } : {}
  return { reply_to: message, thread_root: threadRoot ?? message }
}

/** The model's "post nothing" answer, with punctuation and case ignored ("NO_REPLY.", "no_reply"). */
export const isNoReply = (text: string) => text.replace(/[^A-Za-z_]/g, "").toUpperCase() === NO_REPLY

/** Reply text stays under message.send's text limit (64 KiB). */
const REPLY_BYTES = 60 * 1024
export const clipReply = (text: string) => {
  const enc = new TextEncoder()
  if (enc.encode(text).length <= REPLY_BYTES) return text
  let out = [...text]
  while (enc.encode(out.join("")).length > REPLY_BYTES - 16) out = out.slice(0, Math.floor(out.length * 0.9))
  return `${out.join("")}\n[... cut]`
}
