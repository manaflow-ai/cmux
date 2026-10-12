import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { call, deliver, memberRow, mirroredTeam, PROJECT, teamState, teamStub } from "./team-stack-support.ts"
import { inDO, sessionToken, worker } from "./team-ssh-support.ts"

/**
 * cx-3bi.43 security review of 87785f2cae50: a removal from a Stack team must end every way in
 * (install tokens, open sockets), a Stack owner's removal must land, one TEAM_NOT_FOUND must not
 * delete a team, and a stuck removal must back off instead of looping.
 */
const removeInStack = async (t: Awaited<ReturnType<typeof mirroredTeam>>) => {
  t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
  const r = await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })
  expect(r.status).toBe(200)
  return r
}

/** A socket and a way to wait (bounded) for its close. */
const openSocket = async (scope: "team" | "cloud", token: string, team: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/${scope}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}, team.${team}` } })
  expect(res.status, `${scope} socket`).toBe(101)
  const ws = res.webSocket!
  let closed: number | undefined
  let wake: (() => void) | undefined
  const frames: Array<any> = []
  ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string)))
  ws.addEventListener("close", (e) => {
    closed = e.code
    wake?.()
  })
  ws.accept()
  const closedWithin = async (ms: number) => {
    if (closed === undefined) await Promise.race([new Promise<void>((r) => (wake = r)), new Promise<void>((r) => setTimeout(r, ms))])
    return closed
  }
  return { closedWithin, frames }
}

describe("Stack team webhook review fixes (cx-3bi.43)", { timeout: 60_000 }, () => {
  it("P1-1: user.ensure with x-cmux-team keeps the personal team, and an install token naming the Stack team loses it at removal", async () => {
    const t = await mirroredTeam()
    const ensured = await call(t.token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" }, t.team)
    expect(ensured.body.ok, JSON.stringify(ensured.body)).toBe(true)
    expect(ensured.body.value.personal_team).toBe(personalTeamIdFor(t.user))
    // A token whose team claim is the Stack team (what a stored personal_team of the Stack team would mint).
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await call(t.token, "/v1/ops", { op: "install.register", params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: "cli", device_name: "laptop", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli" })
    expect(reg.body.ok, JSON.stringify(reg.body)).toBe(true)
    const { token } = await mintAccessToken(env as never, { user: t.user, team: t.team, install: reg.body.value.id, grant: reg.body.value.grant })
    expect((await call(token, "/v1/read", { op: "team_vm.status", params: {} })).status).toBe(200)
    await removeInStack(t)
    const after = await call(token, "/v1/read", { op: "team_vm.status", params: {} })
    expect(after.status, JSON.stringify(after.body)).toBe(403)
  })

  it("P1-2: a removed member's open team and cloud sockets close", async () => {
    const t = await mirroredTeam()
    const team = await openSocket("team", t.token, t.team)
    const cloud = await openSocket("cloud", t.token, t.team)
    expect(await team.closedWithin(50)).toBeUndefined()
    await removeInStack(t)
    expect(await team.closedWithin(3000)).toBe(4401)
    // CloudDO hears it from TeamDO's outbox.
    await fireAlarm(teamStub(t.team))
    expect(await cloud.closedWithin(3000)).toBe(4401)
  })

  it("P2-1: Stack's removal of a member who is an owner of the Stack team lands", async () => {
    const t = await mirroredTeam()
    // The Stack member is an owner in cmux (team roles, cx-3bi.4 seed it the same way), beside another owner.
    const seeded = await inDO(teamStub(t.team), async (instance) => [
      instance.submitSystem("team.member.remove", { user: t.user }, crypto.randomUUID()),
      instance.submitSystem("team.member.provision", { user: t.user, role: "owner", source: "stack", display_name: "Aziz" }, crypto.randomUUID()),
      instance.submitSystem("team.member.provision", { user: userIdFor(PROJECT, crypto.randomUUID()), role: "owner", source: "stack", display_name: "Other owner" }, crypto.randomUUID())
    ])
    for (const r of seeded) expect(r.frames.find((f: any) => f.t === "reject")).toBeUndefined()
    expect(await memberRow(t.team, t.user)).toMatchObject({ role: "owner" })
    const r = await removeInStack(t)
    expect(r.body).toMatchObject({ ok: true, outcome: "member_absent" })
    expect(await memberRow(t.team, t.user)).toBeNull()
    expect((await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)).status).toBe(403)
  })

  it("P2-2: a TEAM_NOT_FOUND read on a non-delete event changes nothing and asks Stack again later", async () => {
    const t = await mirroredTeam()
    t.w.teams.delete(t.stackTeam)
    const r = await deliver("team_membership.created", { team_id: t.stackTeam, user_id: t.stackUser })
    expect(r.status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeUndefined()
    expect(await memberRow(t.team, t.user)).not.toBeNull()
    // Stack answers again; the re-check (made due now) keeps the team and the member.
    t.w.teams.set(t.stackTeam, "Acme")
    const before = t.w.calls()
    await inDO(teamStub(t.team), async (_i, st) => st.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0`))
    await fireAlarm(teamStub(t.team))
    expect(t.w.calls()).toBeGreaterThan(before)
    expect((await teamState(t.team)).team?.deleted_at).toBeUndefined()
    expect(await memberRow(t.team, t.user)).not.toBeNull()
    // A team.deleted that Stack confirms still deletes.
    t.w.teams.delete(t.stackTeam)
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    expect((await teamState(t.team)).team?.deleted_at).toBeGreaterThan(0)
  })

  it("P2-3: a deleted team whose member removal makes no progress backs off instead of waking at once", async () => {
    const t = await mirroredTeam()
    t.w.teams.delete(t.stackTeam)
    // Removal is stuck (a submit that commits nothing); count the attempts.
    const attempts = { n: 0 }
    await inDO(teamStub(t.team), async (instance) => {
      const real = instance.submitSystem.bind(instance)
      instance.submitSystem = (op: string, params: unknown, key: string) => (op === "team.member.remove" ? (attempts.n++, { frames: [] }) : real(op, params, key))
    })
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    await fireAlarm(teamStub(t.team))
    expect(attempts.n).toBe(1)
    // An alarm right after a stalled removal does not try again before the backoff ends.
    await fireAlarm(teamStub(t.team))
    expect(attempts.n).toBe(1)
    expect(await memberRow(t.team, t.user)).not.toBeNull()
  })

  it("an outsider session cannot open the Stack team's socket", async () => {
    const t = await mirroredTeam()
    const outsider = await sessionToken(crypto.randomUUID(), "Eve")
    const res = await worker.fetch("https://api.test/v1/wire/team", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${outsider}, team.${t.team}` } })
    expect(res.status).toBe(403)
  })
})
