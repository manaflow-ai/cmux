import { expect, it, vi } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { call, deliver, mirroredTeam, teamIdOf, teamStub, useStack } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { env } from "cloudflare:workers"
import type { Env } from "../src/env.ts"
import { TeamDO } from "../src/team-do.ts"
import { PersonalTenantIdentityError } from "../src/team-vm-api-personal-stack.ts"
import { PersonalTenantStore } from "../src/team-vm-api-personal-store.ts"
import { PROJECT } from "./team-stack-support.ts"

interface Marker { readonly version: number; readonly project: string; readonly team: string; readonly user: string; readonly stack_user: string; readonly nonce: string }
const STACK_TEAM = "cb48f8e3-5ebf-4a16-918b-9adb7d6948a7"
const fixture = async (tenant = STACK_TEAM) => {
  const t = await mirroredTeam("Personal VM tenant")
  const personal = personalTeamIdFor(t.user)
  let creates = 0, uncertain = false, visible = true
  let found: Array<{ id: string; marker: Marker }> = []
  const stack = {
    find: async (_marker: Marker) => visible ? found : [],
    create: async (marker: Marker) => {
      creates++
      const receipt = { id: tenant, marker }
      found = [receipt]
      if (uncertain) throw new Error("test lost response")
      return receipt
    },
    members: async (_id: string) => [t.stackUser]
  }
  await inDO(teamStub(personal), async (instance) => { instance.personalStack = stack })
  return { ...t, personal, stack, creates: () => creates, marker: () => found[0]?.marker, loseResponse: () => { uncertain = true }, answer: () => { uncertain = false }, visible: (value: boolean) => { visible = value } }
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
    // A normal request opens the persisted owner engine; direct construction bypasses the platform's input gate.
    expect((await restarted.readOp(t.personal, { identity: `user:${t.user}`, kind: "session", user: t.user, team: t.personal }, "team.directory", {})).ok).toBe(true)
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

it("logs one line per ensure that is not ready, naming the reason, the ledger and the failed Stack call", async () => {
  const t = await fixture()
  t.stack.create = async () => { throw new PersonalTenantIdentityError(true, { call: "create", status: 403, code: "TEAM_CREATE_DENIED" }) }
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
  try {
    expect(await ensure(t.personal)).toHaveProperty("status", "pending")
    const lines = warn.mock.calls.map((c) => JSON.parse(String(c[0])) as Record<string, unknown>).filter((l) => l.msg === "personal vm api tenant not ready")
    expect(lines).toEqual([expect.objectContaining({
      team: t.personal, status: "pending", reason: "Stack create failed", create: true,
      stack: { call: "create", status: 403, code: "TEAM_CREATE_DENIED" },
      ledger: expect.objectContaining({ phase: "prepared", attempts: 2, nextAt: expect.any(Number) })
    })])
    warn.mockClear()
    expect(await ensure(t.personal)).toHaveProperty("status", "pending")
    expect(warn.mock.calls.map((c) => JSON.parse(String(c[0])) as Record<string, unknown>).filter((l) => l.msg === "personal vm api tenant not ready")).toEqual([
      expect.objectContaining({ reason: "backing off after a failed create" })
    ])
  } finally { warn.mockRestore() }
})

it("does not resend a successful create when its membership confirmation fails", async () => {
  const t = await fixture()
  t.stack.members = async () => { throw new PersonalTenantIdentityError(true) }
  expect(await ensure(t.personal)).toHaveProperty("status", "pending")
  t.visible(false)
  expect(await ensure(t.personal)).toHaveProperty("status", "pending")
  expect(t.creates()).toBe(1)
})

it("becomes ready on the next ensure once the members read answers, even with the ledger backed off for an hour", async () => {
  const t = await fixture()
  const listed = t.stack.members
  t.stack.members = async () => { throw new PersonalTenantIdentityError(true, { call: "members", status: 404 }) }
  for (let i = 0; i < 12; i++) expect(await ensure(t.personal)).toHaveProperty("status", "pending")
  const ledger = await inDO(teamStub(t.personal), async (instance) => new PersonalTenantStore(instance.sqlStore).read())
  expect(ledger).toMatchObject({ phase: "creating" })
  expect(ledger!.nextAt! - Date.now()).toBeGreaterThan(30 * 60_000)
  t.stack.members = listed
  expect(await ensure(t.personal)).toMatchObject({ status: "ready", target: { tenant: STACK_TEAM } })
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

it("denies new work after the backing Stack team is deleted while retaining cleanup routing", async () => {
  const t = await fixture()
  expect(await ensure(t.personal)).toHaveProperty("status", "ready")
  t.w.teams.set(STACK_TEAM, "Personal")
  t.w.members.set(`${STACK_TEAM}:${t.stackUser}`, "Owner")
  await useStack(STACK_TEAM, t.w)
  expect((await deliver("team.created", { id: STACK_TEAM, display_name: "Personal" })).status).toBe(200)
  expect(await read(t.personal)).toHaveProperty("tenant", STACK_TEAM)
  t.w.teams.delete(STACK_TEAM)
  expect((await deliver("team.deleted", { id: STACK_TEAM })).status).toBe(200)
  expect(await read(t.personal)).toBeNull()
  expect(await ensure(t.personal)).toHaveProperty("status", "unavailable")
  expect(await inDO(teamStub(t.personal), async (instance) => instance.vmApiTenant(t.personal, "cleanup"))).toHaveProperty("tenant", STACK_TEAM)
  expect(t.creates()).toBe(1)
})

it("fails closed when a second member joins the tenant after provisioning", async () => {
  const TENANT = crypto.randomUUID()
  const t = await fixture(TENANT)
  expect(await ensure(t.personal)).toHaveProperty("status", "ready")
  expect(await read(t.personal)).toHaveProperty("tenant", TENANT)
  t.stack.members = async () => [t.stackUser, crypto.randomUUID()]
  // Past the short positive cache of the last solo-membership read.
  const later = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 5 * 60_000)
  try {
    expect(await read(t.personal)).toBeNull()
    expect(await inDO(teamStub(t.personal), async (instance) => instance.vmApiTenant(t.personal, "cleanup"))).toHaveProperty("tenant", TENANT)
  } finally { later.mockRestore() }
})

it("never mirrors the personal tenant's Stack team or its members as a cmux team", async () => {
  const TENANT = crypto.randomUUID()
  const t = await fixture(TENANT)
  expect(await ensure(t.personal)).toHaveProperty("status", "ready")
  const invitee = crypto.randomUUID()
  t.w.teams.set(TENANT, "Personal")
  t.w.members.set(`${TENANT}:${t.stackUser}`, "Owner")
  t.w.members.set(`${TENANT}:${invitee}`, "Invitee")
  const getTeam = t.w.fake.getTeam
  t.w.fake.getTeam = async (id: string) => { const team = await getTeam(id); return team && id === TENANT ? { ...team, vm_personal_tenant: true } : team }
  await useStack(TENANT, t.w)
  expect((await deliver("team.created", { id: TENANT, display_name: "Personal" })).body).toMatchObject({ outcome: "vm_personal_tenant_ignored" })
  expect((await deliver("team_membership.created", { team_id: TENANT, user_id: invitee })).body).toMatchObject({ outcome: "vm_personal_tenant_ignored" })
  const mirror = teamIdOf(TENANT)
  expect(await inDO(teamStub(mirror), async (instance) => instance.vmApiTenantState(mirror))).toBe("unknown")
  expect(await inDO(teamStub(mirror), async (instance) => instance.vmApiTenant(mirror, "operate"))).toBeNull()
})

it("starts over under a fresh nonce once a lost create stays unfound past its window", async () => {
  const TENANT = crypto.randomUUID()
  const t = await fixture(TENANT)
  t.loseResponse()
  t.visible(false)
  expect(await ensure(t.personal)).toMatchObject({ status: "pending" })
  const first = t.marker()?.nonce
  expect(await ensure(t.personal)).toMatchObject({ status: "pending" })
  expect(t.creates()).toBe(1)
  t.answer()
  const later = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 25 * 3600_000)
  try {
    expect(await ensure(t.personal)).toMatchObject({ status: "ready", target: { tenant: TENANT } })
  } finally { later.mockRestore() }
  expect(t.creates()).toBe(2)
  expect(t.marker()?.nonce).not.toBe(first)
})
