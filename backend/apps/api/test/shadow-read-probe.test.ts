import { describe, expect, it } from "vitest"
import { shadowReadProbe } from "../src/shadow-read-probe.ts"

/**
 * The shadow-read soak needs traffic: home.search is rarely used and the feed sweep pages users once a day,
 * so staging logged no projection.read event in 24 h (2026-10-28). The 15-minute compare cron now pages
 * every user id through the same read path (feed.users), so each run gives match or diff events.
 */
describe("shadow read probe", () => {
  // Like listUsersPostgres: ids after `after`, ascending, at most `limit`; a short page is the last one.
  const pages = (ids: Array<string>) => {
    const calls: Array<string | null> = []
    const listUsers = async (after: string | null, limit: number) => {
      calls.push(after)
      const from = after === null ? 0 : ids.indexOf(after) + 1
      return ids.slice(from, from + limit)
    }
    return { calls, listUsers }
  }

  it("pages every user id once and reports the count", async () => {
    const { calls, listUsers } = pages(["u1", "u2", "u3", "u4", "u5"])
    expect(await shadowReadProbe({ PROJECTION_READS: "shadow" }, listUsers, { pageSize: 2 })).toEqual({ ran: true, pages: 3, users: 5 })
    expect(calls).toEqual([null, "u2", "u4"])
  })

  it("stops at the page cap", async () => {
    const { calls, listUsers } = pages(Array.from({ length: 50 }, (_, i) => `u${String(i).padStart(2, "0")}`))
    expect(await shadowReadProbe({ PROJECTION_READS: "shadow" }, listUsers, { pageSize: 1, maxPages: 3 })).toEqual({ ran: true, pages: 3, users: 3 })
    expect(calls.length).toBe(3)
  })

  it("does nothing unless reads are in shadow mode", async () => {
    for (const mode of [undefined, "postgres", "mysql"]) {
      const { calls, listUsers } = pages(["u1"])
      expect(await shadowReadProbe({ PROJECTION_READS: mode }, listUsers)).toEqual({ ran: false, pages: 0, users: 0 })
      expect(calls).toEqual([])
    }
  })
})
