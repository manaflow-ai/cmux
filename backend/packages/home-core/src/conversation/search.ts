import type { ConversationHead, Message } from "./types.ts"
import { currentParticipant } from "./validate.ts"

/**
 * `conversation-search` (local owner) and `home.search` (cloud read) share this
 * read model and its corpus (`conformance/conversation-search-cases.json`):
 * Home messages only, in conversations where the actor is a current
 * participant, from `joined_seq` on when the group hides older history. The
 * match is a case-insensitive substring of the text parts: both sides are
 * lower-cased per code point (Unicode default lower case, as Rust
 * `char::to_lowercase`), so it works for every script without a tokenizer.
 * Order: newest `created_at` first, then conversation id ascending, then seq
 * descending. A retracted message never matches.
 */
export const MAX_QUERY_CHARS = 200
export const SNIPPET_CHARS = 120
export const MIN_LIMIT = 1
export const MAX_LIMIT = 100

export interface SearchInput {
  readonly query: string
  readonly limit: number
}

export interface SearchSource {
  readonly head: ConversationHead
  /** The conversation's messages (any order). */
  readonly messages: ReadonlyArray<Message>
}

export interface SearchHit {
  readonly conversation: string
  readonly title: string
  readonly seq: number
  readonly message_id: string
  readonly author: string
  readonly created_at: string
  readonly snippet: string
}

export type SearchResult = { readonly ok: true; readonly hits: ReadonlyArray<SearchHit> } | { readonly ok: false; readonly code: "invalid_query" | "invalid_limit" }

/** One code point to its lower case (may be more than one code point, for example "İ"). */
const fold = (ch: string) => ch.toLowerCase()

/** Text of a message for matching and snippets (text parts joined by one space). */
export const messageText = (message: Message): string =>
  message.parts
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()

/** Up to SNIPPET_CHARS characters centered on the first match, with an ellipsis where cut. */
export const snippetOf = (text: string, at: number, length: number): string => {
  const chars = [...text]
  // `at` and `length` are code-point offsets in `text`.
  if (chars.length <= SNIPPET_CHARS) return text
  const start = Math.max(0, Math.min(at - Math.floor((SNIPPET_CHARS - length) / 2), chars.length - SNIPPET_CHARS))
  const end = Math.min(chars.length, start + SNIPPET_CHARS)
  return `${start > 0 ? "…" : ""}${chars.slice(start, end).join("")}${end < chars.length ? "…" : ""}`
}

export const searchConversations = (actor: string, input: SearchInput, sources: ReadonlyArray<SearchSource>): SearchResult => {
  const query = typeof input.query === "string" ? input.query.trim() : ""
  if (query.length === 0 || [...query].length > MAX_QUERY_CHARS || /[\u0000-\u001f\u007f]/.test(query)) return { ok: false, code: "invalid_query" }
  if (!Number.isInteger(input.limit) || input.limit < MIN_LIMIT || input.limit > MAX_LIMIT) return { ok: false, code: "invalid_limit" }
  const needle = [...query].map(fold)
  const hits: Array<SearchHit> = []
  for (const { head, messages } of sources) {
    const me = currentParticipant(head, actor)
    if (!me || me.kind === "address") continue
    const from = head.settings?.history_visible === "since_join" ? (me.joined_seq ?? 0) + 1 : 1
    for (const message of messages) {
      if (message.conversation !== head.id || message.retracted_at !== undefined || message.seq < from) continue
      const text = messageText(message)
      // Fold per code point so offsets map back to the original text.
      const folded = [...text].map(fold)
      const at = folded.findIndex((_, i) => needle.every((ch, j) => folded[i + j] === ch))
      if (at < 0) continue
      hits.push({ conversation: head.id, title: head.title, seq: message.seq, message_id: message.id, author: message.author, created_at: message.created_at, snippet: snippetOf(text, at, needle.length) })
    }
  }
  hits.sort((a, b) => (a.created_at === b.created_at ? (a.conversation === b.conversation ? b.seq - a.seq : a.conversation < b.conversation ? -1 : 1) : a.created_at < b.created_at ? 1 : -1))
  return { ok: true, hits: hits.slice(0, input.limit) }
}
