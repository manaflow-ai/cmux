import { env } from "cloudflare:workers"
import { createExecutionContext, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { agentKeyProblem, resolveTeamSharedKey } from "../src/team-agent-keys.ts"
import { ModelKeys, modelKeyForTeam } from "../src/model-keys.ts"
import { deliver, call } from "./team-stack-support.ts"
import { codeOf, op, read, rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"

/**
 * Team shared agent keys (Cloud multiplayer, contract C4): owners and admins set, replace and
 * remove a team's key per agent; members only see whether one is set; the key itself never leaves
 * TeamDO except through resolveTeamSharedKey (the model route), and never sits in the ledger,
 * events, state or audit in plain text.
 */
const testEnv = env as unknown as { TEAM_DO: DurableObjectNamespace }
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const teamStub = (team: string) => testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))
const KEY = "sk-team-shared-0123456789-abcd"
const OTHER = "sk-team-shared-9876543210-wxyz"

describe("team shared agent keys (C4)", { timeout: 60_000 }, () => {
  it("an owner sets, replaces and removes a key; status never returns it; resolve does", async () => {
    const t = await rolesTeam()
    const empty = await read(t.creator.token, "team.agent_key.status", {}, t.team)
    expect(empty.body.value).toMatchObject({ team: t.team, can_manage: true, agents: [{ agent: "claude", set: false, kind: null, hint: null }, { agent: "codex", set: false }] })
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude")).toBeNull()

    const set = await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: KEY }, t.team)
    expect(set.body).toMatchObject({ ok: true, value: { agent: "claude", set: true, kind: "api_key", generation: 1, hint: "abcd", updated_by: t.creator.user } })
    expect(JSON.stringify(set.body)).not.toContain(KEY)
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude")).toEqual({ kind: "api_key", secret: KEY })
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "codex")).toBeNull()

    const replaced = await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "oauth", secret: OTHER }, t.team)
    expect(replaced.body.value).toMatchObject({ generation: 2, kind: "oauth", hint: "wxyz" })
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude")).toEqual({ kind: "oauth", secret: OTHER })

    const status = await read(t.creator.token, "team.agent_key.status", {}, t.team)
    expect(JSON.stringify(status.body)).not.toContain(KEY)
    expect(JSON.stringify(status.body)).not.toContain(OTHER)

    expect((await op(t.creator.token, "team.agent_key.remove", { agent: "claude" }, t.team)).body.value).toEqual({ agent: "claude", removed: true })
    expect((await op(t.creator.token, "team.agent_key.remove", { agent: "claude" }, t.team)).body.value).toEqual({ agent: "claude", removed: false })
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude")).toBeNull()
    // A removal raises the generation (2 to 3): the next set never reuses a sealed row's address.
    expect((await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: KEY }, t.team)).body.value).toMatchObject({ generation: 4 })

    await inDO(teamStub(t.team), async (_instance, state) => {
      const everything = JSON.stringify(["own_events", "own_ledger", "own_state", "own_outbox"].map((table) => state.storage.sql.exec(`SELECT * FROM ${table}`).toArray()))
      expect(everything).not.toContain(KEY)
      expect(everything).not.toContain(OTHER)
      // Audited: set, replaced, removed, set (agent and generation only).
      expect(everything).toContain("team.agent_key.audit")
      const sealed = state.storage.sql.exec("SELECT sealed FROM team_agent_keys").toArray()
      expect(sealed.length).toBe(1)
      expect(String(sealed[0]?.sealed)).not.toContain(KEY)
    })
  })

  it("a member sees the status without the hint and may not change a key; the wire path is refused", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    expect((await op(t.creator.token, "team.agent_key.set", { agent: "codex", kind: "api_key", secret: KEY }, t.team)).body.ok).toBe(true)
    const status = await read(member.token, "team.agent_key.status", {}, t.team)
    expect(status.body.value).toMatchObject({ can_manage: false, agents: [{ agent: "claude", set: false }, { agent: "codex", set: true, kind: "api_key", hint: null }] })
    expect(codeOf(await op(member.token, "team.agent_key.set", { agent: "codex", kind: "api_key", secret: OTHER }, t.team))).toBe("auth.forbidden")
    expect(codeOf(await op(member.token, "team.agent_key.remove", { agent: "codex" }, t.team))).toBe("auth.forbidden")
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "codex")).toEqual({ kind: "api_key", secret: KEY })
    // Never through the reducer (the key would land in the ledger's params hash).
    await inDO(teamStub(t.team), async (instance) => {
      const frames = instance.submitSystem("team.agent_key.set", { agent: "codex", kind: "api_key", secret: OTHER }, "wire").frames
      expect(frames.find((f: { t: string }) => f.t === "reject")).toBeTruthy()
    })
  })

  it("a non-member is refused; a removed member stops resolving the team's key at once", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    const outsider = await rolesTeam()
    expect((await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: KEY }, t.team)).body.ok).toBe(true)
    const foreign = await call(outsider.creator.token, "/v1/read", { op: "team.agent_key.status", params: {} }, t.team)
    expect(codeOf(foreign), "the edge refuses a non-member before the team reads anything").toBe("team.not_member")
    const store = new ModelKeys(createExecutionContext(), testEnv as never)
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude", { user: member.user })).toEqual({ kind: "api_key", secret: KEY })
    expect(await store.resolveTeamSharedKey(t.team, "claude", member.user)).toEqual({ kind: "api_key", secret: KEY })
    t.w.members.delete(`${t.stackTeam}:${member.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: member.stackUser })).status).toBe(200)
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude", { user: member.user })).toBeNull()
    // The platform's path too: a removed member's machine token still names them for up to an hour.
    expect(await store.resolveTeamSharedKey(t.team, "claude", member.user)).toBeNull()
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude", { user: outsider.creator.user })).toBeNull()
    expect(await resolveTeamSharedKey(testEnv as never, t.team, "claude", { user: t.creator.user })).toEqual({ kind: "api_key", secret: KEY })
  })

  it("a retried set is answered from its first write; bad keys are refused before sealing", async () => {
    const t = await rolesTeam()
    const key = crypto.randomUUID()
    const body = { op: "team.agent_key.set", params: { agent: "claude", kind: "api_key", secret: KEY }, idempotency_key: key, origin: "cli" }
    const first = await call(t.creator.token, "/v1/ops", body, t.team)
    const again = await call(t.creator.token, "/v1/ops", body, t.team)
    expect(first.body.value.generation).toBe(1)
    expect(again.body).toMatchObject({ ok: true, replayed: true, value: { generation: 1 } })
    expect(codeOf(await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: "has a space in it" }, t.team))).toBe("validation.invalid")
    expect(codeOf(await op(t.creator.token, "team.agent_key.set", { agent: "gemini", kind: "api_key", secret: KEY }, t.team))).toBe("validation.invalid")
    expect(codeOf(await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: "short" }, t.team))).toBe("validation.invalid")
    expect(agentKeyProblem("oauth", '{"tokens":{"refresh_token":"r"}}')).toBeUndefined()
    expect(agentKeyProblem("oauth", "{not json")).toBeTruthy()
    expect(agentKeyProblem("api_key", ` ${KEY}`)).toBeTruthy()
  })
})

describe("the platform's MODEL_KEYS store (C2/C4 seam)", { timeout: 60_000 }, () => {
  it("answers the team's shared key, null for anything else, and null for an owner key", async () => {
    const t = await rolesTeam()
    expect((await op(t.creator.token, "team.agent_key.set", { agent: "claude", kind: "api_key", secret: KEY }, t.team)).body.ok).toBe(true)
    const store = new ModelKeys(createExecutionContext(), testEnv as never)
    const owner = t.creator.user
    expect(await store.resolveTeamSharedKey(t.team, "claude", owner)).toEqual({ kind: "api_key", secret: KEY })
    expect(await store.resolveTeamSharedKey(t.team, "claude"), "a call that names no owner").toBeNull()
    expect(await store.resolveTeamSharedKey(t.team, "codex", owner)).toBeNull()
    expect(await store.resolveTeamSharedKey(t.team, "gemini", owner)).toBeNull()
    expect(await store.resolveTeamSharedKey("not-a-team", "claude", owner)).toBeNull()
    expect(await store.resolveTeamSharedKey("team_00000000000000000000", "claude", owner), "an unknown team").toBeNull()
    expect(await modelKeyForTeam(testEnv as never, 42, "claude", owner)).toBeNull()
    // A removal moves the status revision on, like a set.
    const before = (await read(t.creator.token, "team.agent_key.status", {}, t.team)).body.revision
    expect((await op(t.creator.token, "team.agent_key.remove", { agent: "claude" }, t.team)).body.value).toEqual({ agent: "claude", removed: true })
    expect(Number((await read(t.creator.token, "team.agent_key.status", {}, t.team)).body.revision)).toBeGreaterThan(Number(before))
    expect(await store.resolveTeamSharedKey(t.team, "claude", owner)).toBeNull()
    // Answered, not missing: over a service binding a missing method throws, which the platform reads as unreachable.
    expect(await store.resolveOwnerProviderKey(t.creator.user, "claude")).toBeNull()
  })
})
