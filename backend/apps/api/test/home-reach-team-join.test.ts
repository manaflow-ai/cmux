import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { sessionToken } from "./setup/home-people.ts"
import { runInDurableObject } from "cloudflare:test"
import { call, deliver, PROJECT, stackWorld, teamIdOf, teamStub, useStack } from "./team-stack-support.ts"

/**
 * Prod 2026-10-29 (a831): right after a Stack team join, conversation.create with the new
 * teammate answered not_reachable for about 3 to 6 s. TeamDO had committed the membership, but
 * each member's UserDO team index (which the reach rule and user.teams.list read) was written
 * only by TeamDO's alarm, after the PlanetScale projection. A new teammate must be able to start
 * a group at once: once the join delivery is answered, both indexes name the team. TeamDO's
 * alarm is held here (in prod it waits seconds behind the PlanetScale projection; in tests that
 * projection fails at once, which hid the race).
 */
const holdAlarm = (team: string) =>
  (runInDurableObject as unknown as (stub: unknown, fn: (instance: { alarm: () => Promise<void> }) => Promise<void>) => Promise<void>)(teamStub(team), async (instance) => {
    instance.alarm = async () => {}
  })
const op = async (token: string, name: string, params: unknown) =>
  (await call(token, "/v1/ops", { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })).body

const joinedJustNow = async () => {
  const w = stackWorld()
  const stackTeam = crypto.randomUUID()
  const team = teamIdOf(stackTeam)
  await useStack(stackTeam, w)
  await holdAlarm(team)
  w.teams.set(stackTeam, "Manaflow")
  const people = await Promise.all(
    ["Ann Lee", "Ben Ross"].map(async (name) => {
      const stackUser = crypto.randomUUID()
      const tag = stackUser.slice(0, 8)
      const token = await sessionToken(stackUser, `${tag}@${tag}.test`, name)
      expect((await op(token, "user.ensure", {})).ok).toBe(true)
      return { stackUser, token, user: userIdFor(PROJECT, stackUser), name }
    })
  )
  expect((await deliver("team.created", { id: stackTeam, display_name: "Manaflow", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  for (const p of people) {
    w.members.set(`${stackTeam}:${p.stackUser}`, p.name)
    expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: p.stackUser })).status).toBe(200)
  }
  return { team, ann: people[0]!, ben: people[1]! }
}

describe("a new teammate reaches the team at once after a join", { timeout: 60_000 }, () => {
  it("starts a group with a teammate right after the join delivery", async () => {
    const { ann, ben } = await joinedJustNow()
    const group = await op(ben.token, "conversation.create", {
      kind: "group",
      title: "Manaflow",
      participants: [
        { id: ben.user, kind: "human", display_name: ben.name },
        { id: ann.user, kind: "human", display_name: ann.name }
      ]
    })
    expect(group.error, JSON.stringify(group.error)).toBeUndefined()
    expect(group.value.conversation.id).toBeTruthy()
  })

  it("the teammate who was already in the team starts one too", async () => {
    const { ann, ben } = await joinedJustNow()
    const group = await op(ann.token, "conversation.create", {
      kind: "group",
      title: "Manaflow",
      participants: [
        { id: ann.user, kind: "human", display_name: ann.name },
        { id: ben.user, kind: "human", display_name: ben.name }
      ]
    })
    expect(group.error, JSON.stringify(group.error)).toBeUndefined()
  })

  it("user.teams.list names the team right after the join delivery", async () => {
    const { team, ben } = await joinedJustNow()
    const listed = (await call(ben.token, "/v1/read", { op: "user.teams.list", params: {} })).body
    expect((listed.value.teams as Array<{ id: string }>).map((t) => t.id)).toContain(team)
  })
})
