import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { signSvixContent } from "../../../../libs/svix-webhook/src/svix.ts"
import { stackServer } from "../src/stack-server.ts"
import { handleStackWebhook } from "../src/stack-webhook.ts"
import type { Env } from "../src/env.ts"
import { SECRET, stackWorld, teamIdOf, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"

/**
 * cx-f5tk4: the sign-in service answered 429 to our team reads during a recovery burst, and every
 * 429 made the sender retry. The webhook route paces deliveries per project (STACK_READ_LIMIT):
 * over the pace it answers a retryable 503 with no TeamDO wake and no read; the sign-in client
 * retries one short 429 itself.
 */
const testEnv = env as unknown as Env

/** A fixed-window limiter like the Workers binding: `limit` passes per window, then refuses. */
const windowLimiter = (limit: number) => {
  let used = 0
  return { binding: { limit: async () => ({ success: ++used <= limit }) } as unknown as RateLimit, used: () => used }
}

const signed = async (type: string, data: unknown) => {
  const body = JSON.stringify({ type, data })
  const id = `msg_${crypto.randomUUID().replace(/-/g, "")}`
  const ts = String(Math.floor(Date.now() / 1000))
  const sig = `v1,${await signSvixContent(SECRET, `${id}.${ts}.${body}`)}`
  return new Request("https://api.test/v1/hooks/stack", { method: "POST", headers: { "content-type": "application/json", "svix-id": id, "svix-timestamp": ts, "svix-signature": sig }, body })
}

describe("Stack webhook pace (cx-f5tk4)", { timeout: 120_000 }, () => {
  it("a burst of 150 signed deliveries never reads the sign-in service above the pace; each ends 200 or a retryable 503", async () => {
    const PACE = 6
    // The faked sign-in service: a 429 for any read past its quota in this window.
    const QUOTA = 20
    const w = stackWorld()
    let reads = 0
    let tooMany = 0
    const guarded = <A extends Array<unknown>, R>(f: (...a: A) => Promise<R>) => async (...a: A): Promise<R> => {
      if (++reads > QUOTA) {
        tooMany++
        throw new Error("stack GET team returned 429")
      }
      return f(...a)
    }
    const fake = { ...w.fake, getTeam: guarded(w.fake.getTeam), listTeamMembers: guarded(w.fake.listTeamMembers), getTeamMember: guarded(w.fake.getTeamMember) }
    const stackTeams = Array.from({ length: 30 }, (_, i) => `pace-${crypto.randomUUID().slice(0, 8)}-${i}`)
    for (const t of stackTeams) {
      w.teams.set(t, `Team ${t}`)
      await inDO(teamStub(teamIdOf(t)), async (instance) => {
        instance.stack = fake
      })
    }
    const limiter = windowLimiter(PACE)
    const paced = { ...testEnv, STACK_READ_LIMIT: limiter.binding } as Env
    const answers = await Promise.all(Array.from({ length: 150 }, async (_, i) => {
      const res = await handleStackWebhook(await signed("team.created", { id: stackTeams[i % stackTeams.length] }), paced)
      return { status: res.status, body: (await res.json()) as any }
    }))
    expect(limiter.used()).toBe(150)
    const ok = answers.filter((a) => a.status === 200)
    const later = answers.filter((a) => a.status === 503)
    expect(ok.length + later.length).toBe(150)
    expect(ok.length).toBeLessThanOrEqual(PACE)
    expect(later.every((a) => a.body.error?.retryable === true)).toBe(true)
    expect(later.filter((a) => a.body.error?.code === "webhook.paced").length).toBeGreaterThanOrEqual(150 - PACE)
    // Only paced-through deliveries read: team.created reads the team and its member list.
    expect(reads).toBeLessThanOrEqual(PACE * 2)
    expect(tooMany).toBe(0)
  })

  it("over the pace, a delivery wakes no TeamDO and reads nothing; a limiter error holds too", async () => {
    const wake = { get: () => { throw new Error("TeamDO must not wake") }, idFromName: (n: string) => n }
    for (const limiter of [{ limit: async () => ({ success: false }) }, { limit: async () => { throw new Error("limiter down") } }]) {
      const res = await handleStackWebhook(await signed("team.created", { id: "pace-none" }), { ...testEnv, STACK_READ_LIMIT: limiter as unknown as RateLimit, TEAM_DO: wake as unknown as Env["TEAM_DO"] } as Env)
      expect(res.status).toBe(503)
      expect(((await res.json()) as any).error).toMatchObject({ code: "webhook.paced", retryable: true })
    }
  })

  it("the sign-in client retries one short 429, and gives up on a second 429 or a long Retry-After", async () => {
    const keyed = { ...testEnv, STACK_SECRET_SERVER_KEY: "test-server-key" } as Env
    const team = { id: "t", display_name: "T", client_read_only_metadata: {} }
    const replies = (list: Array<Response>) => {
      let n = 0
      return { http: async () => list[n++] ?? new Response("{}", { status: 500 }), calls: () => n }
    }
    const waits: Array<number> = []
    const wait = async (ms: number) => void waits.push(ms)
    const once = replies([new Response("{}", { status: 429, headers: { "retry-after": "1" } }), Response.json(team)])
    expect(await stackServer(keyed, once.http, wait)!.getTeam("t")).toMatchObject({ display_name: "T" })
    expect(once.calls()).toBe(2)
    expect(waits).toEqual([1000])
    const twice = replies([new Response("{}", { status: 429 }), new Response("{}", { status: 429 })])
    await expect(stackServer(keyed, twice.http, wait)!.getTeam("t")).rejects.toThrow(/429/)
    expect(twice.calls()).toBe(2)
    const long = replies([new Response("{}", { status: 429, headers: { "retry-after": "30" } })])
    await expect(stackServer(keyed, long.http, wait)!.getTeam("t")).rejects.toThrow(/429/)
    expect(long.calls()).toBe(1)
  })
})
