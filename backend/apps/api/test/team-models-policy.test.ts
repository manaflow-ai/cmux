import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { call } from "./team-stack-support.ts"
import { codeOf, op, read, rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"

/**
 * The members policy for model connections (Settings > Models, cmux-tui/docs/model-connections.md):
 * every member reads it, owners and admins change it in their own session, the defaults apply until
 * then (own connections on, choosing the run-out off), and every change is audited.
 */
const testEnv = env as unknown as { TEAM_DO: DurableObjectNamespace }
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const teamStub = (team: string) => testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))

describe("team members policy for model connections", { timeout: 60_000 }, () => {
  it("answers the defaults, then an admin's change; a field left out keeps its value", async () => {
    const t = await rolesTeam()
    const empty = await read(t.creator.token, "team.models_policy.get", {}, t.team)
    expect(empty.body.value).toEqual({ team: t.team, can_edit: true, own_connections: true, choose_runout: false, revision: 0, updated_at: null, updated_by: null })

    const set = await op(t.creator.token, "team.models_policy.set", { choose_runout: true }, t.team)
    expect(set.body).toMatchObject({ ok: true, value: { own_connections: true, choose_runout: true, revision: 1, updated_by: t.creator.user } })
    const off = await op(t.creator.token, "team.models_policy.set", { own_connections: false }, t.team)
    expect(off.body.value).toMatchObject({ own_connections: false, choose_runout: true, revision: 2 })
    // The same values again change nothing: no new revision, no new audit row.
    const same = await op(t.creator.token, "team.models_policy.set", { own_connections: false, choose_runout: true }, t.team)
    expect(same.body.value).toMatchObject({ revision: 2 })
    expect((await read(t.creator.token, "team.models_policy.get", {}, t.team)).body).toMatchObject({ revision: "2", value: { own_connections: false, choose_runout: true } })

    await inDO(teamStub(t.team), async (_instance, state) => {
      const everything = JSON.stringify(["own_events", "own_ledger"].map((table) => state.storage.sql.exec(`SELECT * FROM ${table}`).toArray()))
      expect(everything).toContain("team.models_policy.audit")
      expect(state.storage.sql.exec("SELECT revision FROM team_models_policy").toArray()).toEqual([{ revision: 2 }])
    })
  })

  it("a member reads it but may not change it; bad params and the wire path are refused", async () => {
    const t = await rolesTeam()
    const member = await t.join("Member", STACK_MEMBER)
    const read1 = await read(member.token, "team.models_policy.get", {}, t.team)
    expect(read1.body.value).toMatchObject({ can_edit: false, own_connections: true, choose_runout: false })
    expect(codeOf(await op(member.token, "team.models_policy.set", { own_connections: false }, t.team))).toBe("auth.forbidden")
    expect(codeOf(await op(t.creator.token, "team.models_policy.set", { own_connections: "no" }, t.team))).toBe("validation.invalid")
    expect((await read(member.token, "team.models_policy.get", {}, t.team)).body.value).toMatchObject({ own_connections: true, revision: 0 })
    // Never through the reducer: only the Worker's route reaches the side table.
    await inDO(teamStub(t.team), async (instance) => {
      const frames = instance.submitSystem("team.models_policy.set", { own_connections: false }, "wire").frames
      expect(frames.find((f: { t: string }) => f.t === "reject")).toBeTruthy()
    })
  })

  it("a non-member is refused", async () => {
    const t = await rolesTeam()
    const outsider = await rolesTeam()
    const foreign = await call(outsider.creator.token, "/v1/read", { op: "team.models_policy.get", params: {} }, t.team)
    expect(codeOf(foreign)).toBe("team.not_member")
    expect(codeOf(await op(outsider.creator.token, "team.models_policy.set", { choose_runout: true }, t.team))).toBeTruthy()
  })
})
