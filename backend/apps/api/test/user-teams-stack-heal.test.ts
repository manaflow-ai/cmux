import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { selectTeam } from "../src/team-select.ts"
import { listUserTeams } from "../src/user-teams.ts"
import { call, PROJECT, stackWorld, teamIdOf, teamStub, useStack } from "./team-stack-support.ts"
import { inDO as runIn } from "./team-ssh-support.ts"
import { sessionToken, worker } from "./team-ssh-support.ts"

const workerEnv = env as unknown as Env

/**
 * A Stack team whose webhook deliveries never reached cmux (a team made before the mirror existed, or
 * events Stack never sent) left every member out of its TeamDO: user.teams.list named only the personal
 * team and Home listed no teammates (prod, 2026-10-29: the "cmux" team, 5 members, none mirrored).
 * user.teams.list now asks Stack which teams the person is in and runs a full team sync for each one
 * TeamDO does not confirm, then lists it.
 */
describe("user.teams.list mirrors a Stack team the webhook never synced", { timeout: 60_000 }, () => {
  const setup = async (name: string) => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const me = crypto.randomUUID()
    const mate = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, name)
    w.members.set(`${stackTeam}:${me}`, "Lawrence")
    w.members.set(`${stackTeam}:${mate}`, "Aziz")
    const token = await sessionToken(me, "Lawrence")
    expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    const principal = { identity: `test:${me}`, kind: "session" as const, user: userIdFor(PROJECT, me), stack_user_id: me }
    return { w, stackTeam, me, mate, token, principal, team: teamIdOf(stackTeam) }
  }
  const members = (token: string, team: string) => call(token, "/v1/read", { op: "team.members.list", params: { limit: 200 } }, team)

  it("syncs the team from Stack and lists it, with every teammate", async () => {
    const s = await setup("cmux")
    // Before: no delivery ever came, so the team does not know its members.
    expect((await members(s.token, s.team)).status).toBe(403)
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => Date.now() })
    expect(r.ok, JSON.stringify(r)).toBe(true)
    const teams = (r as { value: { teams: Array<{ id: string; display_name: string; kind: string }> } }).value.teams
    expect(teams).toContainEqual(expect.objectContaining({ id: s.team, display_name: "cmux", kind: "stack" }))
    const after = await members(s.token, s.team)
    expect(after.status, JSON.stringify(after.body)).toBe(200)
    expect((after.body.value.members as Array<{ display_name: string }>).map((m) => m.display_name).sort()).toEqual(["Aziz", "Lawrence"])
  })

  it("a person's own list is never put in the low lane of the Stack pace (that lane may be full of visitors' teams)", async () => {
    const s = await setup("Busy")
    await runIn(teamStub(s.team), async (instance) => void (instance.stackLowPace = async () => false))
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => Date.now() })
    expect((r as { value: { teams: Array<{ id: string }> } }).value.teams.map((t) => t.id)).toContain(s.team)
  })

  it("asks Stack once per person per window, and not at all without a pace token", async () => {
    const s = await setup("Paced")
    const before = s.w.calls()
    const r = await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => false, now: () => 1_000 })
    expect((r as { value: { teams: Array<unknown> } }).value.teams).toHaveLength(1)
    expect(s.w.calls()).toBe(before)
    await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => 2_000 })
    const once = s.w.calls()
    expect(once).toBeGreaterThan(before)
    await listUserTeams(workerEnv, s.principal, { stack: s.w.fake, pace: async () => true, now: () => 3_000 })
    expect(s.w.calls()).toBe(once)
  })
})

/**
 * Leo's NIGHTLY, 2026-11-11: `cmux whoami` printed "cmux Cloud refused a token for team -" (auth.forbidden)
 * while `cmux vm ls` worked. The app mints its install token for its active Stack team; UserDO.redeem asked
 * that team's TeamDO, which had never mirrored the team from Stack, so it answered "not a member". Two other
 * teams of his minted. The mint, and a session's x-cmux-team, now sync such a team from Stack and ask again.
 */
describe("a team-scoped check syncs a Stack team the webhook never mirrored", { timeout: 60_000 }, () => {
  const setup = async (name: string, inStack = true) => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const me = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, name)
    if (inStack) w.members.set(`${stackTeam}:${me}`, "Leo")
    const token = await sessionToken(me, "Leo")
    const ensured = (await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body
    expect(ensured.ok).toBe(true)
    const user = ensured.value.id as string
    return { w, me, token, user, team: teamIdOf(stackTeam) }
  }
  const post = async (path: string, token: string, body: unknown) => {
    const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
    return { status: res.status, json: (await res.json()) as any }
  }
  /** A mac install's token for `team` (the app's `cmux auth token` mint). */
  const mint = async (s: Awaited<ReturnType<typeof setup>>, team: string) => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const registered = await call(s.token, "/v1/ops", { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "cmux", device_name: "mac", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(registered.body.ok, JSON.stringify(registered.body)).toBe(true)
    const install = registered.body.value.id as string
    const ch = await post("/v1/auth/challenge", s.token, { user: s.user, install, team })
    expect(ch.status, JSON.stringify(ch.json)).toBe(200)
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`)))
    const signature = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    return post("/v1/auth/token", s.token, { user: s.user, install, nonce: ch.json.nonce, signature })
  }
  const healWith = (s: Awaited<ReturnType<typeof setup>>) =>
    runIn(workerEnv.USER_DO.get(workerEnv.USER_DO.idFromName(s.user)), async (instance) => void (instance.stackHeal = { stack: s.w.fake, pace: async () => true, now: () => Date.now() }))

  it("mints the install token for a team Stack lists the person in", async () => {
    const s = await setup("leo@cmux.com's Team")
    // Before: TeamDO never heard of the team, and nothing asks Stack.
    const before = await mint(s, s.team)
    expect(before.status).toBe(403)
    expect(before.json.error?.code ?? before.json.code).toBe("auth.forbidden")
    await healWith(s)
    const after = await mint(s, s.team)
    expect(after.status, JSON.stringify(after.json)).toBe(200)
    expect(after.json.team).toBe(s.team)
  })

  it("still refuses a team Stack does not list the person in", async () => {
    const s = await setup("Not mine", false)
    await healWith(s)
    const r = await mint(s, s.team)
    expect(r.status).toBe(403)
  })

  it("a session's x-cmux-team selects the team once it is synced", async () => {
    const s = await setup("Picked")
    const p = { identity: `test:${s.me}`, kind: "session" as const, user: s.user, team: personalTeamIdFor(s.user), stack_user_id: s.me }
    const none = { stack: undefined, pace: async () => true, now: () => Date.now() }
    expect(await selectTeam(workerEnv, p, s.team, none)).toMatchObject({ ok: false, code: "team.not_member" })
    const fake = { stack: s.w.fake, pace: async () => true, now: () => Date.now() }
    expect(await selectTeam(workerEnv, p, s.team, fake)).toMatchObject({ ok: true, principal: { team: s.team } })
  })

  // Review F1: healing one team took the person's Stack read for the window, and the next user.teams.list got an
  // empty map, so a second unmirrored team went unlisted for ten minutes. The window now hands back the same teams.
  it("healing one team leaves the person's other unmirrored teams to the next list", async () => {
    const s = await setup("First")
    const other = crypto.randomUUID()
    await useStack(other, s.w)
    s.w.teams.set(other, "Second")
    s.w.members.set(`${other}:${s.me}`, "Leo")
    const p = { identity: `test:${s.me}`, kind: "session" as const, user: s.user, team: personalTeamIdFor(s.user), stack_user_id: s.me }
    const fake = { stack: s.w.fake, pace: async () => true, now: () => Date.now() }
    expect(await selectTeam(workerEnv, p, s.team, fake)).toMatchObject({ ok: true, principal: { team: s.team } })
    const r = await listUserTeams(workerEnv, p, fake)
    const ids = (r as { value: { teams: Array<{ id: string }> } }).value.teams.map((t) => t.id)
    expect(ids).toContain(s.team)
    expect(ids).toContain(teamIdOf(other))
  })
})
