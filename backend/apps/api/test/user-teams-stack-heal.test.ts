import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { TOKEN_MINT_DEADLINE_MS, tokenMintDeadline } from "../src/http.ts"
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

/**
 * NEXT Nightly on production, 2026-11-14 (cmuxterm-hq run 43577358598): the app's install-token mint for
 * its active Stack team ran past the app's 25 s limit, for two accounts, while a mint without a team and a
 * personal-team token answered. The mint's heal waited on Stack's team read (10 s a request, plus 429
 * retries) and the team sync (up to 10 s) with no total budget, and /v1/auth/token had no deadline of its own.
 */
describe("a team-scoped mint answers within its budget whatever Stack does", { timeout: 60_000 }, () => {
  const setup = async (name: string) => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const me = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, name)
    w.members.set(`${stackTeam}:${me}`, "Leo")
    const token = await sessionToken(me, "Leo")
    const ensured = (await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body
    expect(ensured.ok).toBe(true)
    return { w, me, token, user: ensured.value.id as string, team: teamIdOf(stackTeam) }
  }
  type Setup = Awaited<ReturnType<typeof setup>>
  const post = async (path: string, token: string, body: unknown) => {
    const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
    return { status: res.status, json: (await res.json()) as any }
  }
  /** One registered mac install; `mint` runs a fresh challenge and token for `team` (the app's `cmux auth token`). */
  const macInstall = async (s: Setup) => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const registered = await call(s.token, "/v1/ops", { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "cmux", device_name: "mac", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(registered.body.ok, JSON.stringify(registered.body)).toBe(true)
    const install = registered.body.value.id as string
    return async (team: string) => {
      const ch = await post("/v1/auth/challenge", s.token, { user: s.user, install, team })
      expect(ch.status, JSON.stringify(ch.json)).toBe(200)
      const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`)))
      const signature = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
      const started = Date.now()
      const r = await post("/v1/auth/token", s.token, { user: s.user, install, nonce: ch.json.nonce, signature })
      return { ...r, ms: Date.now() - started }
    }
  }
  const userDO = (s: Setup) => workerEnv.USER_DO.get(workerEnv.USER_DO.idFromName(s.user))
  /** A Stack whose team read waits until `release()`, then answers as the fake world does. */
  const heldStack = (s: Setup) => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => (release = resolve))
    let calls = 0
    const stack = { listUserTeams: async (u: string) => (calls++, await gate, s.w.fake.listUserTeams(u)) }
    return { stack, release, calls: () => calls }
  }
  const errorOf = (r: { json: any }) => r.json.error ?? r.json

  it("a Stack read that hangs answers a retryable owner.unreachable naming the step, and the next mint succeeds", async () => {
    const s = await setup("Hung Stack")
    const held = heldStack(s)
    await runIn(userDO(s), async (instance) => void (instance.stackHeal = { stack: held.stack, pace: async () => true, now: () => Date.now() }))
    const mint = await macInstall(s)
    const first = await mint(s.team)
    expect(first.status, JSON.stringify(first.json)).toBe(503)
    expect(errorOf(first)).toMatchObject({ code: "owner.unreachable", retryable: true })
    expect(errorOf(first).message).toContain("Stack")
    expect(first.ms).toBeLessThan(10_000)
    // The heal keeps running after the answer: once Stack answers, the team is synced and the next mint succeeds.
    held.release()
    let next = await mint(s.team)
    for (let i = 0; i < 10 && next.status !== 200; i++) {
      await new Promise((resolve) => setTimeout(resolve, 200))
      next = await mint(s.team)
    }
    expect(next.status, JSON.stringify(next.json)).toBe(200)
    expect(next.json.team).toBe(s.team)
    // One Stack read served both mints (the retry waited on the running heal instead of finding no teams).
    expect(held.calls()).toBe(1)
  })

  it("a member TeamDO already knows mints without asking Stack", async () => {
    const s = await setup("Mirrored")
    await runIn(userDO(s), async (instance) => void (instance.stackHeal = { stack: s.w.fake, pace: async () => true, now: () => Date.now() }))
    const mint = await macInstall(s)
    expect((await mint(s.team)).status).toBe(200)
    const held = heldStack(s)
    await runIn(userDO(s), async (instance) => void (instance.stackHeal = { stack: held.stack, pace: async () => true, now: () => Date.now() }))
    const again = await mint(s.team)
    expect(again.status, JSON.stringify(again.json)).toBe(200)
    expect(held.calls()).toBe(0)
    held.release()
  })

  it("/v1/auth/token answers by its deadline when the membership check never does", async () => {
    const s = await setup("Stuck")
    const mint = await macInstall(s)
    let wake!: () => void
    await runIn(userDO(s), async (instance) => void (instance.tokenTeamMember = () => new Promise((resolve) => (wake = () => resolve({ role: "member" })))))
    tokenMintDeadline.ms = 1_000
    try {
      const r = await mint(s.team)
      expect(r.status, JSON.stringify(r.json)).toBe(503)
      expect(errorOf(r)).toMatchObject({ code: "owner.unreachable", retryable: true })
      expect(errorOf(r).message).toContain("token mint")
      expect(r.ms).toBeLessThan(5_000)
    } finally {
      tokenMintDeadline.ms = TOKEN_MINT_DEADLINE_MS
      await runIn(userDO(s), async () => wake?.())
    }
  })
})
