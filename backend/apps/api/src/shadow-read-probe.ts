import { projectionReadMode } from "./projection-reads.ts"

/** Users per probe page (the feed sweep's page size). */
const PROBE_PAGE = 200

/**
 * Pages every user id through `listUsers` while PROJECTION_READS=shadow, so the 15-minute compare cron
 * gives the shadow-read soak traffic: each page is a `feed.users` shadow read that logs a match or a diff.
 * Bounded by `maxPages` (default 25 pages of 200); does nothing in any other read mode.
 */
export const shadowReadProbe = async (
  env: { readonly PROJECTION_READS?: string | undefined },
  listUsers: (after: string | null, limit: number) => Promise<ReadonlyArray<string>>,
  options: { readonly maxPages?: number; readonly pageSize?: number } = {}
): Promise<{ ran: boolean; pages: number; users: number }> => {
  if (projectionReadMode(env) !== "shadow") return { ran: false, pages: 0, users: 0 }
  const maxPages = options.maxPages ?? 25
  const pageSize = options.pageSize ?? PROBE_PAGE
  let after: string | null = null
  let pages = 0
  let users = 0
  while (pages < maxPages) {
    const page = await listUsers(after, pageSize)
    pages++
    users += page.length
    if (page.length < pageSize) break
    after = page[page.length - 1]!
  }
  return { ran: true, pages, users }
}
