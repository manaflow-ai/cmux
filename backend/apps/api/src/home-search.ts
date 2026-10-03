import { conversation as homeConversation } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"

/**
 * `home.search` (home-messaging.md sections 7 and 20): the PlanetScale projection through the
 * read-only Hyperdrive (role search-ro). Permission is membership: a hit needs a current
 * participant row for the caller, and `since_join` is honored through `visible_from_seq`.
 * Retracted messages are deleted from the projection, so they never match. Matching is a
 * case-insensitive substring (pg_trgm index); results are newest first; the snippet is 120
 * code points centered on the match (home-core snippetOf), the same hit shape as the local
 * `conversation-search`.
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
const likeEscape = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`)

/** Opaque cursor: the last hit's (created_at, conversation, seq). */
const encodeCursor = (h: SearchHit) => Buffer.from(JSON.stringify([h.created_at, h.conversation, h.seq])).toString("base64url")
const decodeCursor = (c: string): [string, string, number] | null => {
  try {
    const v = JSON.parse(Buffer.from(c, "base64url").toString("utf8")) as unknown
    return Array.isArray(v) && v.length === 3 && typeof v[0] === "string" && typeof v[1] === "string" && typeof v[2] === "number" ? (v as [string, string, number]) : null
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

export const homeSearch = async (env: Env, principal: Principal, params: SearchParams): Promise<{ ok: true; value: { hits: Array<SearchHit>; cursor?: string } } | { ok: false; code: string; message: string }> => {
  const me = homeConversation.actorOf(principal)
  if (!me || principal.agent) return { ok: false, code: "auth.forbidden", message: "search is for human participants" }
  const q = typeof params.q === "string" ? params.q : ""
  if ([...q].length < 1 || [...q].length > MAX_QUERY_CHARS) return { ok: false, code: "validation.invalid", message: "invalid_query" }
  const limit = params.limit === undefined ? 20 : params.limit
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) return { ok: false, code: "validation.invalid", message: "invalid_limit" }
  const cursor = params.cursor ? decodeCursor(params.cursor) : undefined
  if (params.cursor && !cursor) return { ok: false, code: "validation.invalid", message: "invalid cursor" }
  if (!env.HYPERDRIVE_RO) return { ok: false, code: "home.not_configured", message: "search is not configured on this deployment" }

  const where = [
    "p.participant_id = $1",
    "p.left_at IS NULL",
    "p.kind = 'human'",
    "s.seq > p.visible_from_seq",
    "s.body ILIKE $2 ESCAPE '\\'"
  ]
  const args: Array<unknown> = [me, `%${likeEscape(q)}%`]
  const add = (sql: string, value: unknown) => {
    args.push(value)
    where.push(sql.replace("?", `$${args.length}`))
  }
  if (params.conversation) add("p.conversation_id = ?", params.conversation)
  if (params.author) add("s.author_id = ?", params.author)
  if (params.kind) add("c.kind = ?", params.kind)
  if (params.before) add("s.created_at < ?", params.before)
  if (cursor) {
    args.push(cursor[0], cursor[1], cursor[2])
    const n = args.length
    where.push(`(s.created_at, s.conversation_id, s.seq) < ($${n - 2}::timestamptz, $${n - 1}, $${n})`)
  }
  args.push(limit)
  const sql = `SELECT s.conversation_id, c.title, s.seq, s.message_id, s.author_id, s.created_at, s.body
    FROM home_participants p
    JOIN home_message_search s ON s.conversation_id = p.conversation_id
    JOIN home_conversations c ON c.id = p.conversation_id
    WHERE ${where.join(" AND ")}
    ORDER BY s.created_at DESC, s.conversation_id DESC, s.seq DESC
    LIMIT $${args.length}`

  // Loaded on first search only (as in projection.ts): pg is CommonJS with node:net.
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: env.HYPERDRIVE_RO.connectionString })
  await client.connect()
  try {
    const res = await client.query(sql, args)
    const hits = res.rows.map((r) => hitOf(r, q))
    return { ok: true, value: { hits, ...(hits.length === limit ? { cursor: encodeCursor(hits[hits.length - 1]!) } : {}) } }
  } finally {
    await client.end().catch(() => {})
  }
}
