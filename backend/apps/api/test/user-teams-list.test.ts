import { describe, expect, it } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { clearSignInRules } from "../src/policy-gate.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { call, deliver, mirroredTeam, teamIdOf, teamStub } from "./team-stack-support.ts"
import { inDO, sessionToken, testEnv } from "./team-ssh-support.ts"
import { rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"
// Route tests: drive the API Worker over HTTP; restored by the unit-test lane (slice 5 deleted them by mistake).

const userStub = (user: string) => testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))

/** Writes a team index entry as that team's TeamDO would (system:team:<id>), without the team knowing the user. */
const indexEntry = (user: string, team: string, role = "member") =>
  inDO(userStub(user), async (instance) => {
    instance.bind(user)
    instance.submitSystem("user.team_index", { team, role, kind: "stack" }, `test-index:${team}`, `system:team:${team}`)
  })

const listTeams = (token: string, team?: string) => call(token, "/v1/read", { op: "user.teams.list", params: {} }, team)

const authorityOf = async (token: string, team: string) => {
  const r = await listTeams(token)
  expect(r.status, JSON.stringify(r.body)).toBe(200)
  const row = r.body.value.teams.find((entry: { id: string }) => entry.id === team)
  expect(row).toBeDefined()
  expect(row.authority_version).toMatch(/^[0-9a-f]{64}$/)
  return row.authority_version as string
}

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
    expect(teams.find((entry) => entry.id === t.team)).toMatchObject({ id: t.team, display_name: "Acme Corp", kind: "stack", stack_team: t.stackTeam, role: "member", sso_required: false })
    expect(teams[0]).not.toHaveProperty("stack_team")
    expect(teams).toHaveLength(2)
    expect(r.body.value.incomplete).toBe(false)
    // The list is the user's, whatever team the request acts in.
    const inShared = await listTeams(t.token, t.team)
    expect(inShared.status).toBe(200)
    expect(inShared.body.value.teams).toEqual(teams)
  })

  it("omits a stored reference that belongs to a different canonical owner", async () => {
    const t = await mirroredTeam("Mismatched reference")
    await fireAlarm(teamStub(t.team))
    await inDO(teamStub(t.team), async (instance) => {
      instance.submitSystem("team.stack_mirror", { team: t.team, stack_team: crypto.randomUUID(), display_name: "Mismatched reference" }, crypto.randomUUID())
    })
    const r = await listTeams(t.token)
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    const shared = r.body.value.teams.find((team: { id: string }) => team.id === t.team)
    expect(shared).toMatchObject({ id: t.team, kind: "stack", role: "member" })
    expect(shared).not.toHaveProperty("stack_team")
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
    expect(teams.find((x) => x.id === t.team)).toMatchObject({ stack_team: t.stackTeam, sso_required: true })
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

  it("answers the personal team for a new person before user.ensure", async () => {
    const stackUser = crypto.randomUUID()
    const token = await sessionToken(stackUser, "New")
    const r = await listTeams(token)
    expect(r.status, JSON.stringify(r.body)).toBe(200)
    expect(r.body.value.teams).toHaveLength(1)
    expect(r.body.value.teams[0]).toMatchObject({ kind: "personal", role: "owner" })
  })

  it("changes authority after role changes away and back, while another member's authority stays stable", async () => {
    const t = await rolesTeam(), member = await t.join("Member", STACK_MEMBER)
    await fireAlarm(teamStub(t.team))
    const first = await authorityOf(member.token, t.team)
    const owner = await authorityOf(t.creator.token, t.team)
    expect(await authorityOf(member.token, t.team)).toBe(first)
    t.w.perms.set(`${t.stackTeam}:${member.stackUser}`, [...STACK_MEMBER, "cmux:admin"])
    expect((await deliver("team_permission.created", { id: "cmux:admin", team_id: t.stackTeam, user_id: member.stackUser })).status).toBe(200)
    const promoted = await authorityOf(member.token, t.team)
    expect(promoted).not.toBe(first)
    t.w.perms.set(`${t.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_permission.deleted", { id: "cmux:admin", team_id: t.stackTeam, user_id: member.stackUser })).status).toBe(200)
    const restored = await authorityOf(member.token, t.team)
    expect(restored).not.toBe(first)
    expect(restored).not.toBe(promoted)
    expect(await authorityOf(t.creator.token, t.team)).toBe(owner)
  })

  it("changes authority on leave and rejoin with the same role", async () => {
    const t = await mirroredTeam("Rejoin")
    await fireAlarm(teamStub(t.team))
    const first = await authorityOf(t.token, t.team)
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    t.w.perms.delete(`${t.stackTeam}:${t.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    const left = await listTeams(t.token)
    expect(left.body.value.teams.some((entry: { id: string }) => entry.id === t.team)).toBe(false)
    t.w.members.set(`${t.stackTeam}:${t.stackUser}`, "Member")
    t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_membership.created", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    await fireAlarm(teamStub(t.team))
    expect(await authorityOf(t.token, t.team)).not.toBe(first)
  })

  it("changes authority when the team's policy version changes", async () => {
    const t = await rolesTeam()
    await fireAlarm(teamStub(t.team))
    const first = await authorityOf(t.creator.token, t.team)
    const changed = await call(t.creator.token, "/v1/ops", { op: "team.policy.update", params: {
      changes: [{ key: "updates.minimumVersion", value: { value: "2.4.0", mode: "enforced" } }], expected_version: 0, reason: "test"
    }, idempotency_key: crypto.randomUUID(), origin: "cli" }, t.team)
    expect(changed.body.ok, JSON.stringify(changed.body)).toBe(true)
    clearSignInRules()
    expect(await authorityOf(t.creator.token, t.team)).not.toBe(first)
  })

  it("keeps implicit personal authority stable across its first creation", async () => {
    const stackUser = crypto.randomUUID(), user = userIdFor(testEnv.STACK_PROJECT_ID, stackUser)
    const token = await sessionToken(stackUser, "New owner"), team = personalTeamIdFor(user)
    const first = await authorityOf(token, team)
    const ensured = await inDO(teamStub(team), async (instance) => instance.submit(team,
      { identity: user, kind: "session", user, team },
      { t: "op", op: "team.ensure_personal", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" }))
    expect(ensured.frames.some((frame: { t: string }) => frame.t === "result")).toBe(true)
    expect(await authorityOf(token, team)).toBe(first)
  })

  it("keeps membership incarnations out of subscriber event rows", async () => {
    const t = await rolesTeam(), member = await t.join("Member", STACK_MEMBER)
    const observed = await inDO(teamStub(t.team), async (instance) => {
      const engine = instance.bind(t.team), frames: Array<unknown> = []
      engine.submit({ identity: "system:team", kind: "system" }, { t: "op", op: "team.member.provision",
        params: { user: member.user, role: "admin", source: "stack", display_name: "Member" }, idempotency_key: crypto.randomUUID(), origin: "script"
      }, (_target: string, frame: unknown) => frames.push(frame))
      return { frames, incarnation: engine.rows.get("member_authority", member.user)?.row.incarnation }
    })
    expect(typeof observed.incarnation).toBe("string")
    expect(observed.frames.some((frame: any) => frame.t === "event")).toBe(true)
    const publicFrames = JSON.stringify(observed.frames)
    expect(publicFrames).not.toContain('"member_authority"')
    expect(publicFrames).not.toContain('"incarnation"')
  })

  it("never reuses authority when a decided key ages out of its ledger", async () => {
    const t = await rolesTeam(), member = await t.join("Member", STACK_MEMBER)
    const versions = await inDO(teamStub(t.team), async (instance) => {
      const engine = instance.bind(t.team)
      const provision = (role: string, key: string) => {
        const frames: Array<any> = []
        engine.submit({ identity: "system:team", kind: "system" }, { t: "op", op: "team.member.provision",
          params: { user: member.user, role, source: "stack", display_name: "Member" }, idempotency_key: key, origin: "script"
        }, (_target: string, frame: unknown) => frames.push(frame))
        expect(frames.some((frame) => frame.t === "event")).toBe(true)
      }
      provision("admin", "reusable-key")
      const first = (await instance.membership(t.team, member.user)).authority_version
      provision("member", "another-key")
      engine.pruneLedger(Date.now() + 1)
      provision("admin", "reusable-key")
      const later = (await instance.membership(t.team, member.user)).authority_version
      return { first, later }
    })
    expect(versions.later).not.toBe(versions.first)
  })
})
