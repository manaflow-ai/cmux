import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { sessionToken } from "./setup/home-people.ts"
import { call, deliver, PROJECT, stackWorld, teamIdOf, teamStub, useStack } from "./team-stack-support.ts"

/**
 * Team group chats (a625): two members of one shared (Stack) team reach each other in Home
 * whichever team their request acts in. A session acts in its personal team unless it names
 * another (x-cmux-team), and Home DMs and groups are not team-scoped, so the reach rule checks
 * every team in the caller's UserDO team index (home-messaging.md 16.7), each confirmed by its
 * TeamDO. Each person has their own email domain, so same-domain trust is not what lets them in.
 */
const op = async (token: string, name: string, params: unknown) =>
  (await call(token, "/v1/ops", { op: name, params, idempotency_key: crypto.randomUUID(), origin: "user" })).body

const teamOfTwo = async () => {
  const w = stackWorld()
  const stackTeam = crypto.randomUUID()
  const team = teamIdOf(stackTeam)
  await useStack(stackTeam, w)
  w.teams.set(stackTeam, "Manaflow")
  const people = await Promise.all(
    ["Ann Lee", "Ben Ross"].map(async (name) => {
      const stackUser = crypto.randomUUID()
      w.members.set(`${stackTeam}:${stackUser}`, name)
      const tag = stackUser.slice(0, 8)
      const token = await sessionToken(stackUser, `${tag}@${tag}.test`, name)
      expect((await op(token, "user.ensure", {})).ok).toBe(true)
      return { stackUser, token, user: userIdFor(PROJECT, stackUser), name }
    })
  )
  expect((await deliver("team.created", { id: stackTeam, display_name: "Manaflow", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  for (const p of people) expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: p.stackUser })).status).toBe(200)
  // TeamDO's outbox writes each member's UserDO team index.
  await fireAlarm(teamStub(team))
  return { w, stackTeam, team, ann: people[0]!, ben: people[1]! }
}

describe("Home reach between members of one shared team", { timeout: 60_000 }, () => {
  it("a DM by user id and a group with a teammate, from a session in its personal team", async () => {
    const { ann, ben } = await teamOfTwo()
    const dm = await op(ann.token, "dm.open", { peer: ben.user })
    expect(dm.error, JSON.stringify(dm.error)).toBeUndefined()
    const group = await op(ann.token, "conversation.create", { title: "Manaflow", participants: [{ id: ann.user, kind: "human", display_name: ann.name }, { id: ben.user, kind: "human", display_name: "anything" }] })
    expect(group.error, JSON.stringify(group.error)).toBeUndefined()
    const snap = (await call(ben.token, "/v1/read", { op: "conversation.snapshot", params: { conversation: group.value.conversation.id, tail: 0 } })).body
    const members = (snap.value.state.participants as Array<{ id: string; display_name: string; left_at?: number }>).filter((p) => p.left_at === undefined)
    expect(members.map((p) => p.id).sort()).toEqual([ann.user, ben.user].sort())
    // The team's name for Ben, not the name the caller typed.
    expect(members.find((p) => p.id === ben.user)?.display_name).toBe("Ben Ross")
  })

  it("no reach once the teammate left the team, though the index still names it", async () => {
    const { w, stackTeam, ann, ben } = await teamOfTwo()
    w.members.delete(`${stackTeam}:${ben.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: stackTeam, user_id: ben.stackUser })).status).toBe(200)
    expect((await op(ann.token, "dm.open", { peer: ben.user })).error?.code).toBe("not_reachable")
  })
})
