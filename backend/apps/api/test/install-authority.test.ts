import { describe, expect, it } from "vitest"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { authorityClient } from "./install-authority-support.ts"
import { call } from "./pairing-harness.ts"
import { inDO } from "./team-ssh-support.ts"
import { deliver, teamStub } from "./team-stack-support.ts"
import { rolesTeam, STACK_MEMBER } from "./team-roles-support.ts"

describe("install.authority", { timeout: 60_000 }, () => {
  it("returns only its authenticated scope and stays stable for names and another install", async () => {
    const p = await signedInWithInstall("authority-own")
    const c = await authorityClient(p.session, p.user)
    const first = await c.version()
    const renamed = await call("/v1/ops", c.token, { op: "install.rename", params: { install: c.install, name: "Renamed" }, idempotency_key: crypto.randomUUID(), origin: "user" })
    expect(renamed.json.ok).toBe(true)
    await authorityClient(p.session, p.user)
    expect(await c.version()).toBe(first)
    const selected = await c.read({ install: p.install, team: "team_00000000000000000000" })
    expect(selected.status).toBe(400)
    expect(selected.json.value).toBeUndefined()
  })

  it("changes on shared role away and back, and on policy changes", async () => {
    const t = await rolesTeam(), member = await t.join("Member", STACK_MEMBER)
    const c = await authorityClient(member.token, member.user, t.team)
    const owner = await authorityClient(t.creator.token, t.creator.user, t.team)
    const first = await c.version(), ownerFirst = await owner.version()
    t.w.perms.set(`${t.stackTeam}:${member.stackUser}`, [...STACK_MEMBER, "cmux:admin"])
    expect((await deliver("team_permission.created", { id: "cmux:admin", team_id: t.stackTeam, user_id: member.stackUser })).status).toBe(200)
    expect(await c.version()).not.toBe(first)
    t.w.perms.set(`${t.stackTeam}:${member.stackUser}`, STACK_MEMBER)
    expect((await deliver("team_permission.deleted", { id: "cmux:admin", team_id: t.stackTeam, user_id: member.stackUser })).status).toBe(200)
    const restored = await c.version()
    expect(restored).not.toBe(first)
    expect(await owner.version()).toBe(ownerFirst)
    const policy = await call("/v1/ops", t.creator.token, { op: "team.policy.update", params: {
      changes: [{ key: "telemetry.level", value: { value: "crash_only", mode: "default" } }], expected_version: 0, reason: "test"
    }, idempotency_key: crypto.randomUUID(), origin: "user" }, { "x-cmux-team": t.team })
    expect(policy.json.ok, JSON.stringify(policy.json)).toBe(true)
    expect(await c.version()).not.toBe(restored)
  })

  it("does not resurrect authority when account identity returns to its old value", async () => {
    const p = await signedInWithInstall("authority-account-aba"), c = await authorityClient(p.session, p.user)
    const first = await c.version()
    const original = await inDO(c.stub, async (instance) => instance.bind(p.user).currentState.user)
    await inDO(c.stub, async (instance) => { instance.bind(p.user).authorityRealNow = instance.bind(p.user).now })
    try {
      for (const [i, email] of ["changed@example.com", original.email].entries()) {
        // Move the owner's injected clock past the stale-session email guard for the return.
        await inDO(c.stub, async (instance) => { instance.bind(p.user).now = () => Date.now() + i * 16 * 60_000 })
        const r = await c.stub.submit(p.user, { identity: `user:${p.user}`, kind: "session", user: p.user, team: p.team,
          stack_user_id: original.stack_user_id, email, email_verified: true },
        { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
        expect(r.frames.some((f: { t: string }) => f.t === "result")).toBe(true)
      }
      expect(await inDO(c.stub, async (instance) => instance.bind(p.user).currentState.user.email)).toBe(original.email)
      expect(await c.version()).not.toBe(first)
    } finally {
      await inDO(c.stub, async (instance) => {
        const engine = instance.bind(p.user)
        engine.now = engine.authorityRealNow
        delete engine.authorityRealNow
      })
    }
  })

  it("refuses session and chief principals and an expired or revoked grant", async () => {
    const p = await signedInWithInstall("authority-refusals"), c = await authorityClient(p.session, p.user)
    await c.version()
    expect((await call("/v1/read", p.session, { op: "install.authority", params: {} })).status).toBe(403)
    expect(await c.stub.readOp(p.user, { ...c.principal, agent: "agt_00000000000000000000" }, "install.authority", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    await inDO(c.stub, async (instance) => {
      const state = instance.bind(p.user).currentState
      state.grants[c.grant] = { ...state.grants[c.grant], expires_at: Date.now() - 1 }
    })
    expect((await c.read()).status).toBe(403)
  })

  it("refuses a grant revoked while the team owner answers", async () => {
    const p = await signedInWithInstall("authority-revoke-in-flight"), c = await authorityClient(p.session, p.user)
    await c.version()
    const team = teamStub(c.team)
    await inDO(team, async (instance) => {
      const proto = Object.getPrototypeOf(instance)
      proto.authorityRealMembership = proto.membership
      proto.membership = async function (entity: string, user: string) {
        const answer = await proto.authorityRealMembership.call(this, entity, user)
        if (entity === c.team && user === c.user) {
          // Construct the RPC stub in this owner's I/O context, as production TeamDO does.
          const owner = this.env.USER_DO.get(this.env.USER_DO.idFromName(user))
          const signedOut = await owner.submit(user, c.principal, { op: "install.sign_out", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })
          if (!signedOut.frames.some((f: { t: string }) => f.t === "result")) throw new Error("fixture did not revoke the install")
        }
        return answer
      }
    })
    try {
      expect(await c.stub.readOp(c.user, c.principal, "install.authority", {})).toMatchObject({ ok: false, code: "auth.forbidden" })
    } finally {
      await inDO(team, async (instance) => {
        const proto = Object.getPrototypeOf(instance)
        proto.membership = proto.authorityRealMembership
        delete proto.authorityRealMembership
      })
    }
  })
})
