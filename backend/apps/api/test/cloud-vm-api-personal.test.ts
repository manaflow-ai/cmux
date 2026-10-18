import { expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { call, mirroredTeam, teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { env } from "cloudflare:workers"
import type { Env } from "../src/env.ts"
import { TeamDO } from "../src/team-do.ts"
import { PersonalTenantIdentityError } from "../src/team-vm-api-personal-stack.ts"
import { PersonalTenantStore } from "../src/team-vm-api-personal-store.ts"
import { PROJECT } from "./team-stack-support.ts"

interface Marker { readonly version: number; readonly project: string; readonly team: string; readonly user: string; readonly stack_user: string; readonly nonce: string }
const STACK_TEAM = "cb48f8e3-5ebf-4a16-918b-9adb7d6948a7"
const fixture = async () => {
  const t = await mirroredTeam("Personal VM tenant")
  const personal = personalTeamIdFor(t.user)
  let creates = 0, uncertain = false, visible = true
  let found: Array<{ id: string; marker: Marker }> = []
  const stack = {
    find: async (_marker: Marker) => visible ? found : [],
    create: async (marker: Marker) => {
      creates++
      const receipt = { id: STACK_TEAM, marker }
      found = [receipt]
      if (uncertain) throw new Error("test lost response")
      return receipt
    },
    members: async (_id: string) => [t.stackUser]
  }
  await inDO(teamStub(personal), async (instance) => { instance.personalStack = stack })
  return { ...t, personal, stack, creates: () => creates, marker: () => found[0]?.marker, loseResponse: () => { uncertain = true }, visible: (value: boolean) => { visible = value } }
}
const ensure = (team: string) => inDO(teamStub(team), async (instance) => instance.ensureVmApiTenant(team))
const read = (team: string) => inDO(teamStub(team), async (instance) => instance.vmApiTenant(team, "operate"))

it("provisions a real personal tenant through its owner and retains it across user.ensure", async () => {
  const t = await fixture()
  expect(await read(t.personal)).toBeNull()
  expect(t.creates()).toBe(0)
  expect(await ensure(t.personal)).toMatchObject({ status: "ready", target: { team: t.personal, tenant: STACK_TEAM } })
  expect(await read(t.personal)).toMatchObject({ team: t.personal, tenant: STACK_TEAM })
  expect(t.creates()).toBe(1)
  expect((await call(t.token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
  expect(await read(t.personal)).toHaveProperty("tenant", STACK_TEAM)
  expect(t.creates()).toBe(1)
})

it("coalesces simultaneous provisioning and replays without another identity create", async () => {
  const t = await fixture()
  const answers = await Promise.all([ensure(t.personal), ensure(t.personal), ensure(t.personal)])
  expect(answers.every((answer) => answer.status === "ready" && answer.target.tenant === STACK_TEAM)).toBe(true)
  expect(t.creates()).toBe(1)
})

it("recovers a lost create answer from trusted server metadata without resending the create", async () => {
  const t = await fixture()
  t.loseResponse()
  expect(await ensure(t.personal)).toMatchObject({ status: "pending" })
  t.visible(false)
  expect(await ensure(t.personal)).toMatchObject({ status: "pending" })
  expect(t.creates()).toBe(1)
  t.visible(true)
  expect(await inDO(teamStub(t.personal), async (_instance, state) => {
    const restarted = new TeamDO(state, env as Env)
    restarted.personalStack = t.stack
    return restarted.ensureVmApiTenant(t.personal)
  })).toMatchObject({ status: "ready", target: { tenant: STACK_TEAM } })
  expect(t.creates()).toBe(1)
})

it("does not bind an unknown owner or provision a shared team a second time", async () => {
  const t = await fixture()
  const unknown = `team_${"f".repeat(20)}`
  expect(await ensure(unknown)).toMatchObject({ status: "unavailable" })
  expect(await inDO(teamStub(unknown), async (_instance, state) => state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'own_%'").toArray())).toEqual([])
  expect(await ensure(t.team)).toMatchObject({ status: "ready", target: { team: t.team, tenant: t.stackTeam } })
  expect(t.creates()).toBe(0)
})

it("refuses a mismatched receipt instead of adopting or creating around it", async () => {
  const t = await fixture()
  t.stack.find = async (marker) => [{ id: STACK_TEAM, marker: { ...marker, project: "other-project" } }]
  expect(await ensure(t.personal)).toMatchObject({ status: "unavailable" })
  expect(await read(t.personal)).toBeNull()
  expect(t.creates()).toBe(0)
})

it("refuses a team that has another member instead of treating it as a solo tenant", async () => {
  const t = await fixture()
  t.stack.members = async () => [t.stackUser, crypto.randomUUID()]
  expect(await ensure(t.personal)).toMatchObject({ status: "unavailable" })
  expect(await read(t.personal)).toBeNull()
})

it("refuses ambiguous identity matches without creating another team", async () => {
  const t = await fixture()
  t.stack.find = async (marker) => [{ id: STACK_TEAM, marker }, { id: "another-team", marker }]
  expect(await ensure(t.personal)).toHaveProperty("status", "unavailable")
  expect(t.creates()).toBe(0)
})

it("keeps the provisioning intent and Stack mapping private in every subscriber projection", async () => {
  const t = await fixture()
  expect(await ensure(t.personal)).toHaveProperty("status", "ready")
  const views = await inDO(teamStub(t.personal), async (instance) => [t.user, "other-user"].map((user) => instance.subscriberView(instance.boundEngine.currentState, { identity: `user:${user}`, kind: "session", user, team: t.personal })))
  expect(JSON.stringify(views)).not.toContain(STACK_TEAM)
  expect(JSON.stringify(views)).not.toContain(t.marker()?.nonce)
})

it("does not resend a successful create when its membership confirmation fails", async () => {
  const t = await fixture()
  t.stack.members = async () => { throw new PersonalTenantIdentityError(true) }
  expect(await ensure(t.personal)).toHaveProperty("status", "pending")
  t.visible(false)
  expect(await ensure(t.personal)).toHaveProperty("status", "pending")
  expect(t.creates()).toBe(1)
})

it("keeps stale retries from reopening an already-sent or completed reservation", async () => {
  const t = await fixture()
  await inDO(teamStub(t.personal), async (instance) => {
    const store = new PersonalTenantStore(instance.sqlStore)
    const prepared = store.reserve({ version: 1, project: PROJECT, team: t.personal, user: t.user, stack_user: t.stackUser, nonce: crypto.randomUUID() }, 1000)
    const sent = store.sent(prepared, 2000)
    store.retry(prepared, 3000, true)
    expect(store.read()).toMatchObject({ phase: "creating", attempts: sent.attempts })
    expect(() => store.sent(prepared, 4000)).toThrow("send conflict")
    store.ready(sent, STACK_TEAM)
    store.retry(sent, 5000, true)
    expect(() => store.ready(sent, "other-team")).toThrow("receipt conflict")
    expect(store.read()).toMatchObject({ phase: "ready", tenant: STACK_TEAM })
  })
})
