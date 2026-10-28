import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"

/**
 * `home.search` (home-messaging.md sections 7 and 20): the PlanetScale Vitess projection through the
 * reader Hyperdrive (home-search-mysql.ts). Permission is membership: a hit needs a current
 * participant row for the caller, and `since_join` is honored through `visible_from_seq`.
 * Retracted messages are deleted from the projection, so they never match. Matching is a
 * case-insensitive substring; results are newest first; the snippet is 120 code points centered
 * on the match (home-core snippetOf), the same hit shape as the local `conversation-search`.
 */

export interface SearchParams {
  readonly q: string
  readonly conversation?: string
  readonly author?: string
  readonly kind?: string
  readonly before?: string
  readonly cursor?: string
  readonly limit?: number
}

export interface SearchHit {
  readonly conversation: string
  readonly title: string | null
  readonly seq: number
  readonly message_id: string
  readonly author: string
  readonly created_at: string
  readonly snippet: string
  readonly ranges: ReadonlyArray<{ start: number; length: number }>
}

/** home-core search.ts MAX_QUERY_CHARS (the catalog caps q at 200 too). */
const MAX_QUERY_CHARS = 200

/** Opaque cursor: the last hit's (created_at, conversation, seq). */
export const encodeCursor = (h: SearchHit) => Buffer.from(JSON.stringify([h.created_at, h.conversation, h.seq])).toString("base64url")
const decodeCursor = (c: string): [string, string, number] | null => {
  try {
    const v = JSON.parse(Buffer.from(c, "base64url").toString("utf8")) as unknown
    return Array.isArray(v) && v.length === 3 && typeof v[0] === "string" && !Number.isNaN(Date.parse(v[0])) && typeof v[1] === "string" && v[1].length <= 64 && Number.isSafeInteger(v[2])
      ? (v as [string, string, number])
      : null
  } catch {
    return null
  }
}

/** Code-point index of the first case-insensitive match of `needle` in `chars`, or -1. */
const findMatch = (chars: ReadonlyArray<string>, needle: ReadonlyArray<string>) => {
  const lower = chars.map((c) => c.toLowerCase())
  for (let i = 0; i + needle.length <= lower.length; i++) if (needle.every((c, k) => lower[i + k] === c)) return i
  return -1
}

/** The hit for one row: snippet (120 code points around the match) and the match range inside it. */
export const hitOf = (row: { conversation_id: string; title: string | null; seq: string | number; message_id: string; author_id: string; created_at: Date | string; body: string }, q: string): SearchHit => {
  const needle = [...q.toLowerCase()]
  const at = Math.max(0, findMatch([...row.body], needle))
  const snippet = homeConversation.snippetOf(row.body, at, needle.length)
  const start = findMatch([...snippet], needle)
  return {
    conversation: row.conversation_id,
    title: row.title,
    seq: Number(row.seq),
    message_id: row.message_id,
    author: row.author_id,
    created_at: new Date(row.created_at).toISOString(),
    snippet,
    ranges: start >= 0 ? [{ start, length: needle.length }] : []
  }
}

export type SearchResult = { ok: true; value: { hits: Array<SearchHit>; cursor?: string } } | { ok: false; code: string; message: string }
export type PreparedSearch = { readonly me: string; readonly q: string; readonly limit: number; readonly cursor: [string, string, number] | undefined }

/** Validation of the caller, the query, the limit and the cursor. */
export const prepareSearch = (principal: Principal, params: SearchParams): PreparedSearch | { ok: false; code: string; message: string } => {
  const me = homeConversation.actorOf(principal)
  if (!me || principal.agent) return { ok: false, code: "auth.forbidden", message: "search is for human participants" }
  const q = typeof params.q === "string" ? params.q : ""
  if ([...q].length < 1 || [...q].length > MAX_QUERY_CHARS) return { ok: false, code: "validation.invalid", message: "invalid_query" }
  const limit = params.limit === undefined ? 20 : params.limit
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) return { ok: false, code: "validation.invalid", message: "invalid_limit" }
  const cursor = params.cursor ? decodeCursor(params.cursor) : undefined
  if (params.cursor && !cursor) return { ok: false, code: "validation.invalid", message: "invalid cursor" }
  if (params.before !== undefined && (typeof params.before !== "string" || Number.isNaN(Date.parse(params.before)))) return { ok: false, code: "validation.invalid", message: "invalid before" }
  // An install's grant must cover reads (sessions are the user).
  if (principal.kind !== "session" && !(principal.grant_classes ?? []).includes("read")) return { ok: false, code: "auth.forbidden", message: "grant does not cover read" }
  return { me, q, limit, cursor: cursor ?? undefined }
}

export const homeSearch = async (env: Env, principal: Principal, params: SearchParams): Promise<SearchResult> =>
  (await import("./home-search-mysql.ts")).homeSearchMysql(env, principal, params)
