import { describe, expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"
import { call } from "./team-stack-support.ts"
import { closeTeamSocket, listenToOwnerWire } from "./team-role-socket-support.ts"
import { deliverRoleNotices, openCloudSockets } from "./cloud-role-socket-support.ts"

const policyVersion = async (token: string, team: string): Promise<number> => {
  const reply = await call(token, "/v1/read", { op: "team.policy.get", params: {} }, team)
  expect(reply.status).toBe(200)
  expect(reply.body.op).toBe("team.policy.get")
  const version = reply.body.value?.policy?.version
  expect(Number.isInteger(version)).toBe(true)
  return version
}

const updatePolicy = async (token: string, team: string, value = ["ssh"]) => {
  const frame = { op: "team.policy.update", params: { expected_version: await policyVersion(token, team),
    changes: [{ key: "cloud.connectServices", value: { value, mode: "enforced" } }] },
    idempotency_key: crypto.randomUUID(), origin: "user" }
  const reply = await call(token, "/v1/ops", frame, team)
  return { reply, frame }
}

describe("Cloud wire policy authority", { timeout: 60_000 }, () => {
  it("a committed shared-team policy change retires every affected idle subscriber", async () => {
    const team = await rolesTeam(), other = await rolesTeam(), member = await team.join("Member", STACK_MEMBER)
    await deliverRoleNotices(team.team); await deliverRoleNotices(other.team)
    const owner = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    const guest = await listenToOwnerWire(member.token, team.team, "cloud")
    const unrelated = await listenToOwnerWire(other.creator.token, other.team, "cloud")
    try {
      expect((await updatePolicy(team.creator.token, team.team)).reply.body.ok).toBe(true)
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, team.creator.user)).toBe(0)
      expect(await openCloudSockets(team.team, member.user)).toBe(0)
      expect(await openCloudSockets(other.team, other.creator.user)).toBe(1)
    } finally { closeTeamSocket(owner); closeTeamSocket(guest); closeTeamSocket(unrelated) }
  })

  it("personal-team policy changes retire an idle owner connection", async () => {
    const team = await rolesTeam(), personal = personalTeamIdFor(team.creator.user)
    const socket = await listenToOwnerWire(team.creator.token, personal, "cloud")
    try {
      expect((await updatePolicy(team.creator.token, personal)).reply.body.ok).toBe(true)
      await deliverRoleNotices(personal)
      expect(await openCloudSockets(personal, team.creator.user)).toBe(0)
    } finally { closeTeamSocket(socket) }
  })

  it("delayed policy delivery preserves a connection admitted under the current version", async () => {
    const team = await rolesTeam()
    await deliverRoleNotices(team.team)
    const old = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    expect((await updatePolicy(team.creator.token, team.team)).reply.body.ok).toBe(true)
    const fresh = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    try {
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, team.creator.user)).toBe(1)
    } finally { closeTeamSocket(old); closeTeamSocket(fresh) }
  })

  it("rollback to the old policy values still retires the old incarnation", async () => {
    const team = await rolesTeam(), before = await policyVersion(team.creator.token, team.team)
    await deliverRoleNotices(team.team)
    const socket = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    try {
      expect((await updatePolicy(team.creator.token, team.team)).reply.body.ok).toBe(true)
      const reply = await call(team.creator.token, "/v1/ops", { op: "team.policy.rollback",
        params: { version: before, expected_version: await policyVersion(team.creator.token, team.team) },
        idempotency_key: crypto.randomUUID(), origin: "user" }, team.team)
      expect(reply.body.ok).toBe(true)
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, team.creator.user)).toBe(0)
    } finally { closeTeamSocket(socket) }
  })

  it("same-value writes, replayed results and refused writes preserve a current subscriber", async () => {
    const team = await rolesTeam(), member = await team.join("Member", STACK_MEMBER)
    const first = await updatePolicy(team.creator.token, team.team)
    expect(first.reply.body.ok).toBe(true)
    await deliverRoleNotices(team.team)
    const socket = await listenToOwnerWire(team.creator.token, team.team, "cloud")
    try {
      expect((await updatePolicy(team.creator.token, team.team)).reply.body.ok).toBe(true)
      const replay = await call(team.creator.token, "/v1/ops", first.frame, team.team)
      expect(replay.body.replayed).toBe(true)
      const denied = (await updatePolicy(member.token, team.team)).reply
      expect(denied.body.ok).toBe(false)
      expect(denied.body.error?.code ?? denied.body.code).toBe("auth.forbidden")
      await deliverRoleNotices(team.team)
      expect(await openCloudSockets(team.team, team.creator.user)).toBe(1)
    } finally { closeTeamSocket(socket) }
  })
})
