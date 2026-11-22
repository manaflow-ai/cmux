import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { encodeCursor, hitOf, prepareSearch, type SearchParams, type SearchResult } from "./home-search.ts"
import { connectMysql, type MysqlTarget } from "./mysql-connect.ts"
import { dt } from "./projection-mysql.ts"

/**
 * `home.search` on the PlanetScale MySQL projection (state-placement.md 4.2, 4.3), the same contract
 * as the Postgres path (home-search.ts): membership through a current human participant row,
 * since_join through visible_from_seq, case-insensitive substring match (LIKE on the
 * utf8mb4_0900_ai_ci body, which also folds accents), newest first, keyset cursor. The server stops
 * the query after 3 s (MAX_EXECUTION_TIME); the caller sees search.unavailable.
 */
const ESC = "|"
const likeEscapeMysql = (s: string) => s.replace(/[|%_]/g, (c) => `${ESC}${c}`)
/** mysql2 dateStrings give UTC wall time without a zone; hits carry ISO UTC. */
const utc = (v: unknown) => (typeof v === "string" && !v.includes("T") ? `${v.replace(" ", "T")}Z` : (v as string))

export const homeSearchMysql = async (env: Env & { PS_MYSQL_RO?: MysqlTarget }, principal: Principal, params: SearchParams): Promise<SearchResult> => {
  const prepared = prepareSearch(principal, params)
  if ("ok" in prepared) return prepared
  const { me, q, limit, cursor } = prepared
  if (!env.PS_MYSQL_RO) return { ok: false, code: "home.not_configured", message: "search is not configured on this deployment" }

  const where = ["p.participant_id = ?", "p.left_at IS NULL", "p.kind = 'human'", "s.seq > p.visible_from_seq", `s.body LIKE ? ESCAPE '${ESC}'`]
  const args: Array<unknown> = [me, `%${likeEscapeMysql(q)}%`]
  const add = (sql: string, ...values: Array<unknown>) => {
    where.push(sql)
    args.push(...values)
  }
  if (params.conversation) add("p.conversation_id = ?", params.conversation)
  if (params.author) add("s.author_id = ?", params.author)
  if (params.kind) add("c.kind = ?", params.kind)
  if (params.before) add("s.created_at < ?", dt(params.before))
  if (cursor) {
    const [at, conversation, seq] = cursor
    const when = dt(at)
    add("(s.created_at < ? OR (s.created_at = ? AND (s.conversation_id < ? OR (s.conversation_id = ? AND s.seq < ?))))", when, when, conversation, conversation, seq)
  }
  args.push(limit)
  const sql = `SELECT /*+ MAX_EXECUTION_TIME(3000) */ s.conversation_id, c.title, s.seq, s.message_id, s.author_id, s.created_at, s.body
    FROM home_participants p
    JOIN home_message_search s ON s.conversation_id = p.conversation_id
    JOIN home_conversations c ON c.id = p.conversation_id
    WHERE ${where.join(" AND ")}
    ORDER BY s.created_at DESC, s.conversation_id DESC, s.seq DESC
    LIMIT ?`

  let client: Awaited<ReturnType<typeof connectMysql>> | null = null
  try {
    client = await connectMysql(env.PS_MYSQL_RO, { timeoutMs: 5000 })
    const [rows] = (await client.query(sql, args)) as [Array<Record<string, unknown>>]
    const hits = rows.map((r) => hitOf({ ...(r as Record<string, unknown>), created_at: utc(r.created_at) } as Parameters<typeof hitOf>[0], q))
    return { ok: true, value: { hits, ...(hits.length === limit ? { cursor: encodeCursor(hits[hits.length - 1]!) } : {}) } }
  } catch {
    return { ok: false, code: "search.unavailable", message: "search failed or timed out; try a longer query" }
  } finally {
    await client?.end().catch(() => {})
  }
}
