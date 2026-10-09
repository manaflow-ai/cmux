import { describe, expect, it } from "vitest"
import { ensureSshTables } from "../src/team-ssh-ca.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { deliver, mirroredTeam, teamState, teamStub } from "./team-stack-support.ts"
import { inDO, sessionToken, testEnv } from "./team-ssh-support.ts"
import { userIdFor } from "../src/domains/user.ts"

/**
 * cx-3bi.43 re-review of 87785f2cae50..20b7e57a7312: an unconfirmed team.deleted must finish later,
 * a cloud socket must not open for a non-member, a stuck removal must still revoke, and a queued
 * delivery past its deadline must not run.
 */
const ns = (testEnv as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO

describe("Stack team webhook re-review fixes (cx-3bi.43)", { timeout: 60_000 }, () => {
  it("P2: a team.deleted that Stack does not confirm yet changes nothing, is not recorded, and its re-check deletes the team later", async () => {
    const t = await mirroredTeam()
    const id = `msg_${crypto.randomUUID().replace(/-/g, "")}`
    const first = await deliver("team.deleted", { id: t.stackTeam }, { id })
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({ ok: true, outcome: "team_delete_pending" })
    expect((await teamState(t.team)).team?.deleted_at).toBeUndefined()
    // Not recorded: the same delivery again is processed, not a duplicate.
    const again = await deliver("team.deleted", { id: t.stackTeam }, { id })
    expect(again.body.duplicate).toBeUndefined()
    // Stack finishes the deletion; the re-check keeps the team.deleted type and tombstones.
    t.w.teams.delete(t.stackTeam)
    await inDO(teamStub(t.team), async (_i, st) => st.storage.sql.exec(`UPDATE stack_team_recheck SET due_at = 0`))
    await fireAlarm(teamStub(t.team))
    expect((await teamState(t.team)).team?.deleted_at).toBeGreaterThan(0)
  })

  it("P3: CloudDO refuses a shared team's socket for a user TeamDO does not list, whatever the principal claims", async () => {
    const t = await mirroredTeam()
    const outsider = userIdFor(testEnv.STACK_PROJECT_ID, crypto.randomUUID())
    const principal = { identity: `session:${outsider}`, kind: "session", user: outsider, team: t.team }
    const stub = ns.get(ns.idFromName(t.team))
    const res = await stub.fetch("https://do/v1/wire/cloud", { headers: { Upgrade: "websocket", "x-cmux-entity": t.team, "x-cmux-principal": JSON.stringify(principal) } })
    expect(res.status).toBe(403)
    // The member itself still connects.
    const member = { identity: `session:${t.user}`, kind: "session", user: t.user, team: t.team }
    const ok = await stub.fetch("https://do/v1/wire/cloud", { headers: { Upgrade: "websocket", "x-cmux-entity": t.team, "x-cmux-principal": JSON.stringify(member) } })
    expect(ok.status).toBe(101)
    ok.webSocket?.accept()
    ok.webSocket?.close()
  })

  it("P3: a set-aside member of a deleted team still has every live certificate revoked", async () => {
    const t = await mirroredTeam()
    t.w.teams.delete(t.stackTeam)
    const serial = 99000 + Math.floor(Math.random() * 900)
    await inDO(teamStub(t.team), async (instance, st) => {
      ensureSshTables(st.storage.sql)
      const now = Date.now()
      st.storage.sql.exec(`INSERT INTO ssh_certs (serial, identity, user, install, key_id, class, generation, issued_at, valid_before) VALUES (?, 'id-x', ?, NULL, 'k', 'agent', 1, ?, ?)`, serial, t.user, now - 60_000, now + 30 * 60_000)
      const real = instance.submitSystem.bind(instance)
      instance.submitSystem = (op: string, params: unknown, key: string) => (op === "team.member.remove" ? { frames: [] } : real(op, params, key))
    })
    expect((await deliver("team.deleted", { id: t.stackTeam })).status).toBe(200)
    for (let i = 0; i < 3; i++) {
      await inDO(teamStub(t.team), async (instance) => {
        instance.stackSync.drainRetryAt = null
      })
      await fireAlarm(teamStub(t.team))
    }
    const revoked = await inDO(teamStub(t.team), async (instance) => instance.boundEngine.currentState.ssh_revoked ?? {})
    expect(Object.keys(revoked)).toContain(String(serial))
  })

  it("P3: a delivery whose deadline passed while queued is dropped before it runs", async () => {
    const t = await mirroredTeam()
    let release: (() => void) | undefined
    const gate = new Promise<void>((r) => (release = r))
    const base = t.w.calls()
    const r = await inDO(teamStub(t.team), async (instance) => {
      const fake = instance.stack
      instance.stack = { ...fake, getTeam: async (id: string) => (await gate, fake.getTeam(id)) }
      const slow = instance.stackSync.deliver({ svix_id: `msg_slow_${crypto.randomUUID()}`, type: "team.updated", stack_team: t.stackTeam }, 10_000)
      const late = instance.stackSync.deliver({ svix_id: `msg_late_${crypto.randomUUID()}`, type: "team.updated", stack_team: t.stackTeam }, 0)
      const lateReply = await late
      release!()
      await slow
      // Let the dropped run settle in the queue.
      await instance.stackSync.deliver({ svix_id: `msg_after_${crypto.randomUUID()}`, type: "team.updated", stack_team: t.stackTeam }, 10_000)
      instance.stack = fake
      return lateReply
    })
    expect(r).toMatchObject({ ok: false })
    // The slow one and the one after asked Stack (team and member list each); the late one never did.
    expect(t.w.calls() - base).toBe(4)
  })

  it("no session of a removed member reconnects to the shared team's cloud socket", async () => {
    const t = await mirroredTeam()
    t.w.members.delete(`${t.stackTeam}:${t.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    const token = await sessionToken(t.stackUser, "Aziz")
    const { worker } = await import("./team-ssh-support.ts")
    const res = await worker.fetch("https://api.test/v1/wire/cloud", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}, team.${t.team}` } })
    expect(res.status).toBe(403)
  })
})
