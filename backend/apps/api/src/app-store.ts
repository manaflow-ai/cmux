import type { AppListing, AppSearch } from "@cmux/protocol"
import type { Env } from "./env.ts"
import { withReadClient, type PlanetscaleReadResult, type ReadQuery } from "./planetscale-read.ts"

/**
 * Worker-side app store reads: app.search over the `apps` projection
 * (generated tsvector + GIN, word-prefix tsquery; no trigram index) and install
 * counts for app.info. Owner `cloud:planetscale`, read-only.
 */

type SearchParams = typeof AppSearch.params.Type

const MAX_TERMS = 8

/**
 * A safe prefix tsquery from free text: letters and digits only, each term
 * `term:*`, AND-ed. Null when the text has no searchable term. The result is
 * passed as a bound parameter to to_tsquery, and contains no tsquery
 * operators besides the ones added here.
 */
export const prefixTsQuery = (text: string | undefined): string | null => {
  const words = (text ?? "").toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []
  const terms = [...new Set(words)].slice(0, MAX_TERMS).map((w) => `${w.slice(0, 64)}:*`)
  return terms.length === 0 ? null : terms.join(" & ")
}

export const decodeCursor = (cursor: string | undefined): number => {
  const m = cursor === undefined ? null : /^o:(\d{1,6})$/.exec(cursor)
  return m ? Number(m[1]) : 0
}

const INSTALL_COUNT = `(SELECT count(*)::int FROM app_installs i WHERE i.app_id = a.id AND i.removed_at IS NULL)`

/** The search statement. Unverified apps and apps without a live version are never listed. */
export const searchStatement = (p: SearchParams): [string, Array<unknown>] => {
  const limit = p.limit ?? 20
  const tsq = prefixTsQuery(p.query)
  return [
    `SELECT a.id, a.name, a.description, a.publisher, a.publisher_name, a.publisher_verified, a.repository, a.icon_url,
            a.categories, a.tier, a.latest_version, ${INSTALL_COUNT} AS install_count
       FROM apps a
      WHERE a.tier <> 'unverified' AND a.latest_version IS NOT NULL
        AND ($1::text IS NULL OR a.search @@ to_tsquery('simple', $1::text))
        AND ($2::text IS NULL OR a.categories @> ARRAY[$2::text])
        AND ($3::text IS NULL OR a.tier = $3::text)
      ORDER BY CASE WHEN $1::text IS NULL THEN 0 ELSE ts_rank(a.search, to_tsquery('simple', $1::text)) END DESC,
               install_count DESC, a.id
      LIMIT $4 OFFSET $5`,
    [tsq, p.category ?? null, p.tier ?? null, limit + 1, decodeCursor(p.cursor)]
  ]
}

interface AppRow {
  id: string
  name: string
  description: string
  publisher: string
  publisher_name: string
  publisher_verified: boolean
  repository: string
  icon_url: string | null
  categories: Array<string>
  tier: AppListing["tier"]
  latest_version: string | null
  install_count: number
}

const toListing = (r: AppRow): AppListing => ({
  id: r.id,
  name: r.name,
  description: r.description,
  publisher: { name: r.publisher_name, github_owner: r.publisher, verified: r.publisher_verified },
  repository: r.repository,
  icon_url: r.icon_url,
  categories: r.categories,
  tier: r.tier,
  latest_version: r.latest_version,
  install_count: Number(r.install_count)
})

export const runSearch = async (q: ReadQuery, p: SearchParams) => {
  const limit = p.limit ?? 20
  const [text, values] = searchStatement(p)
  const { rows } = await q.query<AppRow>(text, values)
  const more = rows.length > limit
  return { apps: rows.slice(0, limit).map(toListing), next_cursor: more ? `o:${decodeCursor(p.cursor) + limit}` : null }
}

export const searchApps = async (env: Env, p: SearchParams): Promise<PlanetscaleReadResult> => {
  try {
    return { ok: true, value: await withReadClient(env, (q) => runSearch(q, p)) }
  } catch (e) {
    return { ok: false, code: "owner.unreachable", message: `app search unavailable: ${String(e)}` }
  }
}

/** Install count from the projection for app.info; 0 when the read binding is absent or fails. */
export const installCount = async (env: Env, app: string): Promise<number> => {
  if (!env.HYPERDRIVE_READ) return 0
  try {
    return await withReadClient(env, async (q) => {
      const { rows } = await q.query<{ n: number }>(`SELECT count(*)::int AS n FROM app_installs WHERE app_id = $1 AND removed_at IS NULL`, [app])
      return Number(rows[0]?.n ?? 0)
    })
  } catch {
    return 0
  }
}
