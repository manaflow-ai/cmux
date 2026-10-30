import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { stackServer } from "../src/stack-server.ts"
import { deliver, memberRow, PROJECT, teamIdOf, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { userIdFor } from "../src/domains/user.ts"

/**
 * cx-f5tk4: production's sign-in service answered 429 to our team reads during a recovery burst, and
 * every failed delivery made the sender retry in waves. Now TeamDO records each delivery durably and
 * answers 200; it reads Stack only with a token of the shared pace, and a sync that cannot read now
 * backs off (1 min doubling to 1 h) and runs again from the alarm. These tests drive the real route,
 * the real Stack client and a faked Stack HTTP boundary that answers 429 over its quota.
 */
const testEnv = env as unknown as Env

/** The shared pace, like the Workers rate limit: `limit` tokens per window; the test opens each window. */
const pace = (limit: number) => {
  let used = 0
  let taken = 0
  return { take: async () => (++used <= limit ? (taken++, true) : false), window: () => void (used = 0), taken: () => taken }
}

/** Stack over HTTP: teams with one member each; a 429 for every request past `quota` in a window. */
const stackHttp = (quota: number) => {
  const teams = new Map<string, string>()
  let inWindow = 0
  let requests = 0
  let tooMany = 0
  let storm = 0
  const http = async (req: Request) => {
    requests++
    if (storm > 0 || ++inWindow > quota) {
      if (storm > 0) storm--
      tooMany++
      return new Response("{}", { status: 429, headers: { "retry-after": "1" } })
    }
    const url = new URL(req.url)
    if (url.pathname.startsWith("/api/v1/team-member-profiles/")) {
      const [t, u] = url.pathname.slice("/api/v1/team-member-profiles/".length).split("/").map(decodeURIComponent)
      return teams.get(t!) === u ? Response.json({ display_name: "Member" }) : new Response("{}", { status: 404, headers: { "x-stack-known-error": "TEAM_MEMBERSHIP_NOT_FOUND" } })
    }
    const team = url.pathname.startsWith("/api/v1/teams/") ? decodeURIComponent(url.pathname.slice("/api/v1/teams/".length)) : url.searchParams.get("team_id") ?? ""
    const user = teams.get(team)
    if (!user) return new Response("{}", { status: 404, headers: { "x-stack-known-error": "TEAM_NOT_FOUND" } })
    if (url.pathname.startsWith("/api/v1/teams/")) return Response.json({ id: team, display_name: `Team ${team.slice(0, 6)}` })
    if (url.pathname === "/api/v1/team-member-profiles") return Response.json({ is_paginated: false, items: [{ team_id: team, user_id: user, display_name: "Member" }] })
    if (url.pathname === "/api/v1/team-permissions") return Response.json({ is_paginated: false, items: [{ id: "team_member", user_id: user, team_id: team }] })
    return new Response("{}", { status: 404 })
  }
  return { teams, http, window: () => void (inWindow = 0), requests: () => requests, tooMany: () => tooMany, storm: (n: number) => void (storm = n) }
}

/** Points every team's TeamDO at the faked Stack and the test pace. */
const wire = async (stackTeams: ReadonlyArray<string>, s: ReturnType<typeof stackHttp>, p: ReturnType<typeof pace>) => {
  const client = stackServer({ ...testEnv, STACK_SECRET_SERVER_KEY: "test-server-key", STACK_PROJECT_ID: PROJECT } as Env, s.http, async () => undefined)!
  for (const t of stackTeams)
    await inDO(teamStub(teamIdOf(t)), async (instance) => {
      instance.stack = client
      instance.stackPace = p.take
    })
}

const pending = (stackTeam: string) =>
  inDO(teamStub(teamIdOf(stackTeam)), async (_i, state) => state.storage.sql.exec<{ k: string; due_at: number; fails: number }>(`SELECT k, due_at, fails FROM stack_team_recheck`).toArray())

/** One step of the injected clock: a new pace and quota window, then every team's alarm work at `now`. */
const step = async (stackTeams: ReadonlyArray<string>, s: ReturnType<typeof stackHttp>, p: ReturnType<typeof pace>, now: number) => {
  p.window()
  s.window()
  for (const t of stackTeams) await inDO(teamStub(teamIdOf(t)), async (instance) => instance.stackSync.wake(now))
}

describe("Stack webhook: queued syncs under the shared pace (cx-f5tk4)", { timeout: 240_000 }, () => {
  it("a burst of 150 signed deliveries: 150 x 200, reads within the pace, no 429, every team syncs in the end", async () => {
    const PACE = 4
    const s = stackHttp(PACE * 3 + 2)
    const p = pace(PACE)
    const stackTeams = Array.from({ length: 30 }, () => crypto.randomUUID())
    for (const t of stackTeams) s.teams.set(t, crypto.randomUUID())
    await wire(stackTeams, s, p)
    const answers = await Promise.all(Array.from({ length: 150 }, (_, i) => deliver("team.created", { id: stackTeams[i % 30], display_name: "T", profile_image_url: null, created_at_millis: 0 })))
    expect(answers.map((a) => a.status)).toEqual(Array(150).fill(200))
    expect(answers.filter((a) => a.body.outcome !== "queued" && a.body.outcome !== "team_mirrored")).toEqual([])
    // At most the pace's syncs read now: three requests each (team, member list, permissions).
    expect(p.taken()).toBeLessThanOrEqual(PACE)
    expect(s.requests()).toBeLessThanOrEqual(PACE * 3)
    // The injected clock: each step opens one pace window and runs every alarm; backoff never passes 1 h.
    let now = Date.now()
    for (let i = 0; i < 40 && (await Promise.all(stackTeams.map(pending))).some((rows) => rows.length > 0); i++) {
      now += 2 * 60 * 60_000
      const before = s.requests()
      await step(stackTeams, s, p, now)
      expect(s.requests() - before).toBeLessThanOrEqual(PACE * 3)
    }
    for (const t of stackTeams) {
      expect(await pending(t)).toEqual([])
      expect(await memberRow(teamIdOf(t), userIdFor(PROJECT, s.teams.get(t)!))).toMatchObject({ role: "member" })
    }
    expect(s.tooMany()).toBe(0)
  })

  it("a 429 storm backs off (1 min doubling to 1 h, ±20 % jitter) and then converges", async () => {
    const s = stackHttp(1000)
    const p = pace(1000)
    const stackTeam = crypto.randomUUID()
    s.teams.set(stackTeam, crypto.randomUUID())
    await wire([stackTeam], s, p)
    // Every request answers 429 for a while: the client's own retry and the delivery both meet it.
    s.storm(1_000_000)
    const r = await deliver("team.created", { id: stackTeam, display_name: "T", profile_image_url: null, created_at_millis: 0 })
    expect(r).toMatchObject({ status: 200, body: { outcome: "queued" } })
    let now = Date.now()
    const waits: Array<number> = []
    for (let i = 0; i < 8; i++) {
      const [row] = await pending(stackTeam)
      expect(row!.fails).toBe(i + 1)
      waits.push(row!.due_at - now)
      now = row!.due_at
      await step([stackTeam], s, p, now)
    }
    // 1, 2, 4, 8, 16, 32, 60, 60 min, each within ±20 %.
    for (const [i, w] of waits.entries()) {
      const want = Math.min(60, 2 ** i) * 60_000
      expect(w).toBeGreaterThanOrEqual(want * 0.8 - 1000)
      expect(w).toBeLessThanOrEqual(want * 1.2 + 1000)
    }
    s.storm(0)
    const [row] = await pending(stackTeam)
    await step([stackTeam], s, p, row!.due_at)
    expect(await pending(stackTeam)).toEqual([])
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, s.teams.get(stackTeam)!))).toMatchObject({ role: "member" })
  })

  it("a reject ends the sync: logged, no pending row, no retry", async () => {
    const s = stackHttp(1000)
    const p = pace(1000)
    const stackTeam = crypto.randomUUID()
    s.teams.set(stackTeam, crypto.randomUUID())
    await wire([stackTeam], s, p)
    await inDO(teamStub(teamIdOf(stackTeam)), async (instance) => {
      instance.realSubmit = instance.submitSystem
      instance.submitSystem = () => ({ frames: [{ t: "reject", code: "test.rejected", message: "no", retryable: false }] })
    })
    const r = await deliver("team.created", { id: stackTeam, display_name: "T", profile_image_url: null, created_at_millis: 0 })
    expect(r).toMatchObject({ status: 200, body: { outcome: "reject:test.rejected" } })
    expect(await pending(stackTeam)).toEqual([])
    const before = s.requests()
    await step([stackTeam], s, p, Date.now() + 24 * 60 * 60_000)
    expect(s.requests()).toBe(before)
    await inDO(teamStub(teamIdOf(stackTeam)), async (instance) => {
      instance.submitSystem = instance.realSubmit
    })
  })

  it("a duplicate svix id answers duplicate, also while its sync is still queued, and reads nothing", async () => {
    const s = stackHttp(1000)
    const p = pace(0)
    const stackTeam = crypto.randomUUID()
    s.teams.set(stackTeam, crypto.randomUUID())
    await wire([stackTeam], s, p)
    const id = `msg_${crypto.randomUUID().replace(/-/g, "")}`
    const first = await deliver("team.created", { id: stackTeam, display_name: "T", profile_image_url: null, created_at_millis: 0 }, { id })
    expect(first.body.outcome).toBe("queued")
    const again = await deliver("team.created", { id: stackTeam, display_name: "T", profile_image_url: null, created_at_millis: 0 }, { id })
    expect(again).toMatchObject({ status: 200, body: { duplicate: true } })
    expect(s.requests()).toBe(0)
    expect((await pending(stackTeam)).length).toBe(1)
  })

  it("a membership merged while another membership's narrow read runs is synced by the merged row's full rerun", async () => {
    const s = stackHttp(1000)
    const p = pace(1000)
    const stackTeam = crypto.randomUUID()
    const u1 = crypto.randomUUID()
    const u2 = crypto.randomUUID()
    s.teams.set(stackTeam, u1)
    await wire([stackTeam], s, p)
    let release: (() => void) | undefined
    const gate = new Promise<void>((r) => (release = r))
    let held = false
    let onHeld: (() => void) | undefined
    const heldNow = new Promise<void>((r) => (onHeld = r))
    const members = [u1, u2]
    const client = stackServer({ ...testEnv, STACK_SECRET_SERVER_KEY: "test-server-key", STACK_PROJECT_ID: PROJECT } as Env, async (req) => {
      const url = new URL(req.url)
      if (url.pathname.startsWith("/api/v1/teams/")) {
        if (!held) {
          held = true
          onHeld!()
          await gate
        }
        return Response.json({ id: stackTeam, display_name: "T" })
      }
      // D0's narrow read: u1's own membership and permissions only.
      if (url.pathname.startsWith("/api/v1/team-member-profiles/")) return Response.json({ display_name: "Member" })
      if (url.pathname === "/api/v1/team-member-profiles") return Response.json({ is_paginated: false, items: members.map((u) => ({ team_id: stackTeam, user_id: u, display_name: "Member" })) })
      if (url.pathname === "/api/v1/team-permissions") {
        const only = url.searchParams.get("user_id")
        return Response.json({ is_paginated: false, items: members.filter((u) => !only || u === only).map((u) => ({ id: "team_member", user_id: u, team_id: stackTeam })) })
      }
      return new Response("{}", { status: 404 })
    }, async () => undefined)!
    await inDO(teamStub(teamIdOf(stackTeam)), async (instance) => {
      instance.stack = client
    })
    // D0 (membership u1) holds its read; D2 (membership u2) merges into the team's row meanwhile.
    const d0 = deliver("team_membership.created", { team_id: stackTeam, user_id: u1 })
    await heldNow
    // D2 waits behind D0's read; past its deadline it answers 200 `queued` (its row stays, merged).
    const d2 = await deliver("team_membership.created", { team_id: stackTeam, user_id: u2 })
    expect(d2).toMatchObject({ status: 200, body: { outcome: "queued" } })
    release!()
    // D0 also waited past its deadline (it answers `queued`); its own narrow read still runs to the end.
    expect((await d0).status).toBe(200)
    // D0 read only u1: u2 arrives only through the merged row's full rerun (inline, or from the alarm).
    for (let i = 0; i < 5 && (await pending(stackTeam)).length > 0; i++) await step([stackTeam], s, p, Date.now() + 10 * 60_000)
    expect(await pending(stackTeam)).toEqual([])
    for (const u of [u1, u2]) expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, u))).toMatchObject({ role: "member" })
  })

  it("a join that found the pace full retries within seconds, not a minute (prod 2026-10-29: 67 s to list a new team)", async () => {
    const s = stackHttp(1000)
    let open = false
    const p = { take: async () => open, window: () => {}, taken: () => 0 }
    const stackTeam = crypto.randomUUID()
    const joiner = crypto.randomUUID()
    s.teams.set(stackTeam, joiner)
    await wire([stackTeam], s, p as unknown as ReturnType<typeof pace>)
    const t0 = Date.now()
    const r = await deliver("team_membership.created", { team_id: stackTeam, user_id: joiner })
    expect(r).toMatchObject({ status: 200, body: { outcome: "queued" } })
    // A full pace frees a token within its 60 s window; a person waits on this join, so it asks again soon.
    const waits: Array<number> = []
    let now = t0
    for (let i = 0; i < 3; i++) {
      const [row] = await pending(stackTeam)
      expect(row!.fails).toBe(i + 1)
      waits.push(row!.due_at - now)
      now = row!.due_at
      await step([stackTeam], s, p as unknown as ReturnType<typeof pace>, now)
    }
    // 5, 10, 20 s, each within ±20 % (plus the delivery's own time).
    for (const [i, w] of waits.entries()) {
      const want = 5_000 * 2 ** i
      expect(w).toBeGreaterThanOrEqual(want * 0.8 - 1000)
      expect(w).toBeLessThanOrEqual(want * 1.2 + 1000)
    }
    open = true
    const [row] = await pending(stackTeam)
    await step([stackTeam], s, p as unknown as ReturnType<typeof pace>, row!.due_at)
    expect(await pending(stackTeam)).toEqual([])
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, joiner))).toMatchObject({ role: "member" })
  })

  it("a flood of syncs for teams cmux never saw (cmux.com visitors) leaves the pace for a join in a known team (prod 2026-10-29)", async () => {
    // Prod: STACK_READ_LIMIT is 4 a minute and anonymous visitors' sign-up teams come about 7 a minute; each
    // team.created of a team cmux never mirrored took a token to learn it is to be ignored, so a join waited ~70 s.
    const s = stackHttp(1000)
    const shared = pace(4)
    const low = pace(2)
    const known = crypto.randomUUID()
    const joiner = crypto.randomUUID()
    const unknown = Array.from({ length: 6 }, () => crypto.randomUUID())
    for (const t of unknown) s.teams.set(t, crypto.randomUUID())
    s.teams.set(known, joiner)
    const all = [known, ...unknown]
    await wire(all, s, shared)
    for (const t of all) await inDO(teamStub(teamIdOf(t)), async (instance) => void (instance.stackLowPace = low.take))
    // The known team is mirrored first, in an earlier pace window.
    expect((await deliver("team.created", { id: known, display_name: "Known", profile_image_url: null, created_at_millis: 0 })).body.outcome).toBe("team_mirrored")
    shared.window()
    low.window()
    // A fresh window: the flood comes first, then the join.
    const lowBefore = low.taken()
    const sharedBefore = shared.taken()
    for (const t of unknown) await deliver("team.created", { id: t, display_name: "T", profile_image_url: null, created_at_millis: 0 })
    expect(low.taken() - lowBefore).toBeLessThanOrEqual(2)
    const join = await deliver("team_membership.created", { team_id: known, user_id: joiner })
    expect(join.body.outcome, JSON.stringify(join.body)).toBe("member_present")
    expect(await memberRow(teamIdOf(known), userIdFor(PROJECT, joiner))).toMatchObject({ role: "member" })
    // Never more Stack reads than the shared pace allows.
    expect(shared.taken() - sharedBefore).toBeLessThanOrEqual(4)
  })

  it("a sync that never gets a token is abandoned after 50 failures, logged with a stable message", async () => {
    const s = stackHttp(1000)
    const p = pace(0)
    const stackTeam = crypto.randomUUID()
    s.teams.set(stackTeam, crypto.randomUUID())
    await wire([stackTeam], s, p)
    const logged: Array<string> = []
    const original = console.error
    console.error = (line: unknown) => void logged.push(String(line))
    try {
      expect((await deliver("team.created", { id: stackTeam, display_name: "T", profile_image_url: null, created_at_millis: 0 })).body.outcome).toBe("queued")
      for (let i = 0; i < 60 && (await pending(stackTeam)).length > 0; i++) {
        const [row] = await pending(stackTeam)
        await step([stackTeam], s, p, row!.due_at)
      }
    } finally {
      console.error = original
    }
    expect(await pending(stackTeam)).toEqual([])
    expect(logged.some((l) => l.includes('"msg":"stack team sync abandoned"'))).toBe(true)
    expect(s.requests()).toBe(0)
  })
})
