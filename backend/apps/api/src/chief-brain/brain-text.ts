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

/** What a message's attachment part says about its file (home-core AttachmentPart; untrusted fields are checked here). */
export interface AttachmentMeta {
  readonly hash?: string
  readonly name?: string
  readonly mime_type?: string
  readonly byte_count?: number
  readonly width?: number
  readonly height?: number
  readonly duration_ms?: number
  readonly preview?: { readonly mime_type?: string }
  readonly poster?: { readonly mime_type?: string }
}

/** Where a turn machine keeps the attachments of its turn (chief-brain-cc/attachments.ts writes them; under the agent user's home). */
export const ATTACHMENT_DIR = "/home/chief/work/.attachments"
/** The largest original a turn machine gets; a larger image or video gets its preview or poster, other files none. */
export const ATTACHMENT_FILE_BYTES = 16 * 1024 * 1024
/** Image types the model reads as images; another image type (HEIC) goes as its preview. */
const READABLE_IMAGES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"])
const EXT: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf",
  "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "application/json": "json", "application/zip": "zip", "application/octet-stream": "bin",
  "video/mp4": "mp4", "video/quicktime": "mov", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/aac": "aac", "audio/wav": "wav"
}
export const extensionOf = (mime: string | undefined) => EXT[mime ?? ""] ?? "bin"
const HASH = /^[0-9a-f]{64}$/

/**
 * Which file of an attachment a turn machine gets: the original (small enough, and an image the model reads, or
 * any other file), the image's preview or the video's poster, or none. The file name holds the hash, and
 * `.preview` / `.poster` for a derived image, so the stager knows what to fetch from the line alone.
 */
export const attachmentFile = (a: AttachmentMeta): { readonly variant?: "preview" | "poster"; readonly file: string } | null => {
  if (!a.hash || !HASH.test(a.hash)) return null
  const mime = a.mime_type ?? ""
  const small = typeof a.byte_count === "number" && a.byte_count > 0 && a.byte_count <= ATTACHMENT_FILE_BYTES
  const image = mime.startsWith("image/")
  const video = mime.startsWith("video/")
  if (small && (image ? READABLE_IMAGES.has(mime) : !video)) return { file: `${ATTACHMENT_DIR}/${a.hash}.${extensionOf(mime)}` }
  if (image && a.preview) return { variant: "preview", file: `${ATTACHMENT_DIR}/${a.hash}.preview.${extensionOf(a.preview.mime_type ?? "image/jpeg")}` }
  if (video && a.poster) return { variant: "poster", file: `${ATTACHMENT_DIR}/${a.hash}.poster.${extensionOf(a.poster.mime_type ?? "image/jpeg")}` }
  return small ? { file: `${ATTACHMENT_DIR}/${a.hash}.${extensionOf(mime)}` } : null
}
/** The attachment file paths a turn's input names (in the order they appear; a path once). */
export const ATTACHMENT_PATH = /\/home\/chief\/work\/\.attachments\/([0-9a-f]{64})(?:\.(preview|poster))?\.([a-z0-9]{1,8})\b/g

const sizeOf = (n: number | undefined) => (typeof n !== "number" || n <= 0 ? "" : n < 1024 ? `${n} B` : n < 1024 * 1024 ? `${Math.round(n / 1024)} KB` : `${(n / (1024 * 1024)).toFixed(1)} MB`)

/**
 * One attachment as the Chief reads it: its name, type, size in pixels and bytes, and (with `files`, on a route
 * whose turn machine gets the bytes) the path of its file there, which the Chief opens with its file tools.
 */
export const attachmentLine = (a: AttachmentMeta, files: boolean): string => {
  const name = (a.name ?? "file").replace(/[\]\n\r]/g, " ")
  const facts = [a.mime_type ?? "", a.width && a.height ? `${a.width}x${a.height}` : "", a.duration_ms ? `${Math.round(a.duration_ms / 1000)} s` : "", sizeOf(a.byte_count)].filter(Boolean).join(" ")
  const at = files ? attachmentFile(a) : null
  const file = at ? `, ${at.variant ? `${at.variant} image` : "file"} ${at.file}` : files ? ", too large to open here" : ""
  return `[attachment: ${name}${facts ? `, ${facts}` : ""}${file}]`
}

const nameOf = (head: Head, id: string) => head.participants.find((p) => p.id === id)?.display_name ?? id

/**
 * One conversation message as the Chief reads it: a header in brackets (conversation, kind, author,
 * thread), then the text, with mentions shown as @name and attachments as one line each. Empty
 * when the message carries nothing a model can read.
 */
export const formatMessage = (head: Head, m: Message, opts: { readonly files?: boolean; readonly owner?: string } = {}): string => {
  const lines: Array<string> = []
  for (const part of m.parts) {
    if (part.type === "text") {
      let text = part.text
      // Mentions right to left so earlier offsets stay valid.
      for (const run of [...(part.runs ?? [])].sort((a, b) => b.start - a.start)) {
        if (run.mention) text = `${text.slice(0, run.start)}@${nameOf(head, run.mention)}${text.slice(run.start + run.length)}`
      }
      if (text.trim()) lines.push(text)
    } else if (part.type === "attachment") lines.push(attachmentLine(part as AttachmentMeta, opts.files === true))
    else if (part.type === "link_preview") lines.push(`[link: ${(part as { url?: string }).url ?? ""}]`)
  }
  if (lines.length === 0) return ""
  const kind = head.kind ?? "group"
  const where = head.title?.trim() ? head.title.trim() : kind
  const thread = m.thread_root ? " · in a thread" : ""
  // In a shared conversation the Chief must tell its owner from everyone else (CHIEF-DONE B3: the owner's
  // requests run, anyone else's keep the approval rule); the owner's own Chief line has only the owner
  // until the owner shares it with teammates (cmux#25569).
  const owner = (kind !== "chief" || sharedChief(head)) && opts.owner !== undefined && m.author === opts.owner ? " (your owner)" : ""
  return `[${where} · ${kind} · ${nameOf(head, m.author)}${owner}${thread}] ${lines.join("\n")}`
}

/**
 * The inbox kind of a Chief's conversation its owner shared with teammates (cmux#25569). It reads like
 * the Chief's own line (the main timeline), but the reply quotes the message it answers, so each person
 * sees which of their messages the Chief answered.
 */
export const SHARED_CHIEF = "chief_shared"

/** More than one person is in this Chief's conversation (its owner shared it). */
export const sharedChief = (head: Head): boolean =>
  head.kind === "chief" && head.participants.filter((p) => p.kind === "human" && p.left_at === undefined).length > 1

/** The kind a message is queued under (cb_inbox.kind, then cb_turn.trigger_kind). */
export const inboxKind = (head: Head): string => (sharedChief(head) ? SHARED_CHIEF : (head.kind ?? "group"))

/** The Chief's line, shared or not, or a DM: replies stay on the main timeline. */
export const oneLine = (kind: string): boolean => kind === "chief" || kind === SHARED_CHIEF || kind === "dm"

/**
 * Where the reply goes: in a channel or group, the thread of the message answered (its own thread,
 * or the thread it is in); in the chief's line or a DM, the main timeline unless that message was
 * already in a thread; in a shared chief's line, the main timeline as a reply to the message answered.
 */
export const replyTarget = (kind: string, message: string, threadRoot: string | null): { reply_to?: string; thread_root?: string } => {
  if (kind === SHARED_CHIEF) return { reply_to: message, ...(threadRoot ? { thread_root: threadRoot } : {}) }
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

/** cmux public ids the last reply pass links: prefix -> deeplink kind (DeepLink `.workspace`, `.tab`, `.pane`). */
const ID_KINDS: Readonly<Record<string, string>> = { ws: "workspace", tab: "tab", pane: "pane" }
/** Code fences, code spans and Markdown links: left as written. */
const KEEP = /```[\s\S]*?(?:```|$)|`[^`\n]*`|\[[^\]\n]*\]\([^)\n]*\)/g
const BARE_ID = /(^|[\s(*_"'|>])((ws|tab|pane)_[0-9a-f]{32})(?![A-Za-z0-9_/-])/g

/**
 * The last pass over a Cloud Chief reply (optchat-chief reply_links.rs, Lawrence 2026-10-26: "reply with links to
 * stuff properly"): a bare cmux id (`ws_…`, `tab_…`, `pane_…`) becomes its `cmux://` link. Code, existing links and
 * URLs stay. Paths are not linked: the Chief's files are on its VM, not the person's Mac.
 */
export const linkIds = (text: string): string => {
  const link = (part: string) => part.replace(BARE_ID, (_m, pre: string, id: string, kind: string) => `${pre}[${ID_KINDS[kind]}](cmux://${ID_KINDS[kind]}/${id})`)
  let out = ""
  let at = 0
  for (const m of text.matchAll(KEEP)) {
    out += link(text.slice(at, m.index)) + m[0]
    at = m.index + m[0].length
  }
  return out + link(text.slice(at))
}
