import { describe, expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { clearSignInRules } from "../src/policy-gate.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { call, deliver, mirroredTeam, teamIdOf, teamStub } from "./team-stack-support.ts"
import { inDO, sessionToken, testEnv } from "./team-ssh-support.ts"

const userStub = (user: string) => testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))

/** Writes a team index entry as that team's TeamDO would (system:team:<id>), without the team knowing the user. */
const indexEntry = (user: string, team: string, role = "member") =>
  inDO(userStub(user), async (instance) => {
    instance.bind(user)
    instance.submitSystem("user.team_index", { team, role, kind: "stack" }, `test-index:${team}`, `system:team:${team}`)
  })

const listTeams = (token: string, team?: string) => call(token, "/v1/read", { op: "user.teams.list", params: {} }, team)

/**
 * cx-5xew: user.teams.list names every team a session may act in (x-cmux-team): the personal
 * team plus each shared team of the UserDO team index that the team's TeamDO confirms. The index
 * is a list hint (eventually consistent); TeamDO.memberRole is the authority, so an entry TeamDO
 * does not confirm is never listed.
 */
describe("user.teams.list (cx-5xew)", { timeout: 60_000 }, () => {
  it("lists the personal team and a confirmed shared team with its name, kind and the caller's role", async () => {
    const t = await mirroredTeam("Acme Corp")
    await fireAlarm(teamStub(t.team))
    const r = await listTeams(t.token)
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    expect(r.body.op).toBe("user.teams.list")
    const teams = r.body.value.teams as Array<{ id: string; display_name: string; kind: string; role: string }>
    expect(teams[0]).toMatchObject({ id: personalTeamIdFor(t.user), kind: "personal", role: "owner", sso_required: false })
    expect(teams).toContainEqual({ id: t.team, display_name: "Acme Corp", kind: "stack", role: "member", sso_required: false })
    expect(teams).toHaveLength(2)
    expect(r.body.value.incomplete).toBe(false)
    // The list is the user's, whatever team the request acts in.
    const inShared = await listTeams(t.token, t.team)
    expect(inShared.status).toBe(200)
    expect(inShared.body.value.teams).toEqual(teams)
  })

  it("drops an index entry its TeamDO does not confirm: a team that never had the user, and a team the user left", async () => {
    const t = await mirroredTeam("Left Inc")
    await fireAlarm(teamStub(t.team))
    const ghost = teamIdOf(crypto.randomUUID())
    await indexEntry(t.user, ghost, "admin")
    // Removed in Stack; the index still names the team until TeamDO's outbox reaches UserDO.
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    await indexEntry(t.user, t.team)
    const index = await inDO(userStub(t.user), async (instance) => instance.bind(t.user).currentState.team_index ?? {})
    expect(Object.keys(index)).toEqual(expect.arrayContaining([ghost, t.team]))
    const r = await listTeams(t.token)
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    expect((r.body.value.teams as Array<{ id: string }>).map((x) => x.id)).toEqual([personalTeamIdFor(t.user)])
    // The server refuses the same teams the list leaves out.
    for (const team of [ghost, t.team]) {
      const refused = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, team)
      expect(refused.status).toBe(403)
      expect(refused.body?.code ?? refused.body?.error?.code).toBe("team.not_member")
    }
  })

  it("flags a confirmed team whose SSO this session lacks (sso_required), instead of hiding it", async () => {
    const t = await mirroredTeam("Sso Co")
    await fireAlarm(teamStub(t.team))
    // Enabling sso.enforce needs a live OIDC connection; this team's rules are stubbed on the TeamDO class
    // (RPC dispatches through the prototype) for this test only.
    await inDO(teamStub(t.team), async (instance) => {
      const proto = Object.getPrototypeOf(instance)
      proto.realSignInRules = proto.signInRules
      proto.signInRules = function (this: unknown, entity: string, ...rest: Array<unknown>) {
        return entity === t.team ? Promise.resolve({ sso_required: true, minimum_version: null, allowed_classes: [] }) : proto.realSignInRules.call(this, entity, ...rest)
      }
    })
    clearSignInRules()
    try {
      await ssoChecks(t)
    } finally {
      await inDO(teamStub(t.team), async (instance) => {
        const proto = Object.getPrototypeOf(instance)
        proto.signInRules = proto.realSignInRules
        delete proto.realSignInRules
      })
      clearSignInRules()
    }
  })

  const ssoChecks = async (t: Awaited<ReturnType<typeof mirroredTeam>>) => {
    const r = await listTeams(t.token)
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    const teams = r.body.value.teams as Array<{ id: string; sso_required: boolean }>
    expect(teams.find((x) => x.id === t.team)).toMatchObject({ sso_required: true })
    expect(teams[0]).toMatchObject({ kind: "personal", sso_required: false })
    // The server refuses the same team for this session with the SSO code.
    const refused = await call(t.token, "/v1/read", { op: "team_vm.status", params: {} }, t.team)
    expect(refused.body?.code ?? refused.body?.error?.code).toBe("auth.sso_required")
  }

  it("answers team.not_member only for the team selection; a role refusal inside the team stays auth.forbidden", async () => {
    const t = await mirroredTeam("Roles Co")
    const outsider = await sessionToken(crypto.randomUUID(), "Eve")
    const out = await call(outsider, "/v1/read", { op: "team.directory", params: {} }, t.team)
    expect(out.status).toBe(403)
    expect(out.body?.code ?? out.body?.error?.code).toBe("team.not_member")
    // A member reading an admins-only read: the op refuses, not the selection.
    const member = await call(t.token, "/v1/read", { op: "team.policy.history", params: {} }, t.team)
    expect(member.status, JSON.stringify(member.body)).toBe(403)
    expect(member.body?.code ?? member.body?.error?.code).toBe("auth.forbidden")
  })

})
