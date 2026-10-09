import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import workerModule from "../src/index.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { call, deliver, memberRow, mirroredTeam, PROJECT, stackWorld, teamIdOf, teamState, teamStub, useStack } from "./team-stack-support.ts"
import { inDO, sessionToken, sshLine, testEnv, worker } from "./team-ssh-support.ts"

/**
 * cx-3bi.43: Stack teams and memberships reach TeamDO through a verified Stack webhook
 * (POST /v1/hooks/stack, Svix signature), and a session acts in a shared team only while
 * TeamDO lists it as a member (header x-cmux-team, checked on every request).
 */
describe("Stack team webhooks into TeamDO (cx-3bi.43)", { timeout: 60_000 }, () => {
  it("a signed team.created and team_membership.created mirror the team and the member; team_membership.deleted removes through team.member.remove", async () => {
    const t = await mirroredTeam("Acme Corp")
    const s = await teamState(t.team)
    expect(s.team).toMatchObject({ id: t.team, kind: "stack", display_name: "Acme Corp" })
    expect(await memberRow(t.team, t.user)).toMatchObject({ user: t.user, role: "member", display_name: "Aziz" })
    // The member's UserDO lists the team (team index, written only by TeamDO).
    await fireAlarm(teamStub(t.team))
    const index = await inDO(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(t.user)), async (instance) => instance.boundEngine?.currentState.team_index ?? {})
    expect(index[t.team]).toMatchObject({ role: "member", kind: "stack" })
    // A team.updated renames from Stack's current name.
    t.w.teams.set(t.stackTeam, "Acme Inc")
    expect((await deliver("team.updated", { id: t.stackTeam, display_name: "Acme Inc", profile_image_url: null, created_at_millis: 0 })).status).toBe(200)
    expect((await teamState(t.team)).team).toMatchObject({ display_name: "Acme Inc" })
    // Removed in Stack: the member row goes, and the cleanup of team.member.remove is pending or done.
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    const removed = await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })
    expect(removed.status).toBe(200)
    expect(await memberRow(t.team, t.user)).toBeNull()
    expect((await teamState(t.team)).member_count).toBe(0)
  })

  it("refuses a bad signature, a wrong secret, a stale or future timestamp and missing headers with 401; a rotation header with two signatures passes", async () => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "Rot")
    const data = { id: stackTeam, display_name: "Rot", profile_image_url: null, created_at_millis: 0 }
    expect((await deliver("team.created", data, { signatures: () => "v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" })).status).toBe(401)
    expect((await deliver("team.created", data, { secret: "whsec_" + btoa("another-secret-of-24-bytes!") })).status).toBe(401)
    expect((await deliver("team.created", data, { ts: Math.floor(Date.now() / 1000) - 600 })).status).toBe(401)
    expect((await deliver("team.created", data, { ts: Math.floor(Date.now() / 1000) + 600 })).status).toBe(401)
    const unsigned = await worker.fetch("https://api.test/v1/hooks/stack", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ type: "team.created", data }) })
    expect(unsigned.status).toBe(401)
    expect((await teamState(teamIdOf(stackTeam))).team).toBeNull()
    expect(w.calls()).toBe(0)
    // Secret rotation: Svix signs with the old and the new secret; one match is enough.
    const rotated = await deliver("team.created", data, { signatures: (good) => `v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ${good}` })
    expect(rotated.status).toBe(200)
    expect((await teamState(teamIdOf(stackTeam))).team).toMatchObject({ kind: "stack", display_name: "Rot" })
  })

  it("a replayed svix-id is a recorded 200 no-op that never asks Stack again", async () => {
    const t = await mirroredTeam()
    const before = t.w.calls()
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    const id = `msg_${crypto.randomUUID().replace(/-/g, "")}`
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser }, { id })).status).toBe(200)
    const calls = t.w.calls()
    expect(calls).toBeGreaterThan(before)
    // Back in Stack, then the old delivery again: nothing changes and Stack is not asked.
    t.w.members.set(`${t.stackTeam}:${t.stackUser}`, "Aziz")
    const replay = await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser }, { id })
    expect(replay.status).toBe(200)
    expect(replay.body).toMatchObject({ ok: true, duplicate: true })
    expect(t.w.calls()).toBe(calls)
    expect(await memberRow(t.team, t.user)).toBeNull()
  })

  it("out of order: a removal delivered before its add leaves no member, and a team deleted before its create stays deleted", async () => {
    const w = stackWorld()
    const stackTeam = crypto.randomUUID()
    const stackUser = crypto.randomUUID()
    const team = teamIdOf(stackTeam)
    await useStack(stackTeam, w)
    w.teams.set(stackTeam, "Order")
    // In Stack the person was added, then removed; the removal arrives first, the add (a retry) after.
    expect((await deliver("team_membership.deleted", { team_id: stackTeam, user_id: stackUser })).status).toBe(200)
    expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: stackUser })).status).toBe(200)
    expect(await memberRow(team, userIdFor(PROJECT, stackUser))).toBeNull()

    // A team created and deleted in Stack: the deletion arrives first, then the create and an add.
    const w2 = stackWorld()
    const gone = crypto.randomUUID()
    const goneTeam = teamIdOf(gone)
    await useStack(gone, w2)
    expect((await deliver("team.deleted", { id: gone })).status).toBe(200)
    expect((await deliver("team.created", { id: gone, display_name: "Ghost", profile_image_url: null, created_at_millis: 0 })).status).toBe(200)
    expect((await deliver("team_membership.created", { team_id: gone, user_id: stackUser })).status).toBe(200)
    const s = await teamState(goneTeam)
    expect(s.team?.deleted_at).toBeGreaterThan(0)
    expect(await memberRow(goneTeam, userIdFor(PROJECT, stackUser))).toBeNull()
  })

  it("a team deleted in Stack removes its members through the removal path and refuses every session", async () => {
    const t = await mirroredTeam()
    expect((await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)).status).toBe(200)
    t.w.teams.delete(t.stackTeam)
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    await fireAlarm(teamStub(t.team))
    await fireAlarm(teamStub(t.team))
    expect(await memberRow(t.team, t.user)).toBeNull()
    const r = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(r.status).toBe(403)
    expect(r.body?.code ?? r.body?.error?.code).toBe("auth.forbidden")
  })

  it("answers 503 not configured (never 500) while STACK_WEBHOOK_SECRET is unset; other events are a 200 no-op", async () => {
    const req = new Request("https://api.test/v1/hooks/stack", { method: "POST", headers: { "svix-id": "msg_x", "svix-timestamp": "1", "svix-signature": "v1,x" }, body: "{}" })
    const res = await (workerModule as unknown as { fetch(r: Request, e: unknown): Promise<Response> }).fetch(req, { ...(env as object), STACK_WEBHOOK_SECRET: undefined })
    expect(res.status).toBe(503)
    expect(((await res.json()) as any).error.code).toBe("webhook.not_configured")
    const other = await deliver("user.updated", { id: crypto.randomUUID() })
    expect(other.status).toBe(200)
    expect(other.body).toMatchObject({ ok: true, ignored: "user.updated" })
    expect((await deliver("team_membership.created", { team_id: "not-a-uuid", user_id: "x" })).status).toBe(400)
  })
})

describe("session team selection (cx-3bi.43)", { timeout: 60_000 }, () => {
  it("a member session runs team_vm.status in the shared team; a non-member naming it gets auth.forbidden; no header keeps the personal team", async () => {
    const t = await mirroredTeam()
    const member = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(member.status, JSON.stringify(member.body)).toBe(200)
    expect(member.body.stream).toBe(`team_vm:${t.team}`)
    const personal = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} })
    expect(personal.status).toBe(200)
    expect(personal.body.stream).not.toBe(`team_vm:${t.team}`)
    const outsider = await sessionToken(crypto.randomUUID(), "Eve")
    for (const [path, body] of [
      ["/v1/read", { op: "team_vm.status", params: {} }],
      ["/v1/ops", { op: "team_vm.ensure_awake", params: { reason: "ssh" }, idempotency_key: crypto.randomUUID(), origin: "cli" }]
    ] as const) {
      const r = await call(outsider, path, body, t.team)
      expect(r.status, JSON.stringify(r.body)).toBe(403)
      expect(r.body?.code ?? r.body?.error?.code).toBe("auth.forbidden")
    }
    // A team id that names no team at all answers the same.
    const nowhere = await call(outsider, "/v1/read", { op: "team_vm.status", params: {} }, teamIdOf(crypto.randomUUID()))
    expect(nowhere.status).toBe(403)
  })

  it("removal through the webhook ends the session's access at once", async () => {
    const t = await mirroredTeam()
    expect((await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)).status).toBe(200)
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    const after = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(after.status).toBe(403)
  })

  it("removing a cert-holding member through the webhook taints the shared team's VM end to end", async () => {
    const t = await mirroredTeam()
    // The owner role comes from team roles (cx-3bi.4), not from Stack membership: seeded through the system op.
    const ownerStack = crypto.randomUUID()
    const owner = userIdFor(PROJECT, ownerStack)
    const seeded = await inDO(teamStub(t.team), async (instance) => instance.submitSystem("team.member.provision", { user: owner, role: "owner", source: "stack", display_name: "Lawrence" }, `seed-owner:${owner}`))
    expect(seeded.frames.find((f: any) => f.t === "reject")).toBeUndefined()
    const ownerToken = await sessionToken(ownerStack, "Lawrence")
    expect((await call(ownerToken, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
    const awake = await call(ownerToken, "/v1/ops", { op: "team_vm.ensure_awake", params: { reason: "ssh" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, t.team)
    expect(awake.body.ok, JSON.stringify(awake.body)).toBe(true)
    const cert = await call(t.token, "/v1/ops", { op: "team_vm.ssh_cert", params: { public_key: await sshLine("ed25519"), class: "agent" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, t.team)
    expect(cert.body.ok, JSON.stringify(cert.body)).toBe(true)
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    await fireAlarm(teamStub(t.team))
    await fireAlarm(teamStub(t.team))
    const status = await call(ownerToken, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(status.body.value.taint).toMatchObject({ epoch: awake.body.value.epoch, users: [t.user], accepted_by: null })
    // The removed member's certificate is on the team KRL.
    const ca = await call(ownerToken, "/v1/read", { op: "team_vm.ssh_ca", params: {} }, t.team)
    expect(ca.status).toBe(200)
    expect(ca.body.value.krl_version).toBeGreaterThan(0)
  })

  it("an install token cannot switch teams with the header", async () => {
    const t = await mirroredTeam()
    // A session token signed as an install would be needed for a real install; the header check refuses any non-session principal.
    const { selectTeam } = await import("../src/team-select.ts")
    const r = await selectTeam(env as never, { identity: "inst_00000000000000000001", kind: "install", user: t.user, team: "team_00000000000000000001", install: "inst_00000000000000000001", grant: "grant_00000000000000000001" }, t.team)
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.code).toBe("auth.forbidden")
  })
})
