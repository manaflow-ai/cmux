import { describe, expect, it } from "vitest"
import { userIdFor } from "../src/domains/user.ts"
import { personalTenantStack } from "../src/team-vm-api-personal-stack.ts"
import { stackServer } from "../src/stack-server.ts"
import { deliver, memberRow, PROJECT, stackWorld, teamIdOf, teamState, useStack } from "./team-stack-support.ts"

/**
 * CMUX-380 (prod 2026-11-11): a person's cmux VM personal tenant, a private Stack team cmux-api creates for the VM
 * API (server_metadata.cmuxVmPersonalTenant), was listed by the sign-in client as one of the person's teams and
 * became the app's active team; `cmux auth token` for it was refused, and every sync answered
 * vm_personal_tenant_ignored. Server metadata is invisible to clients, so the tenant is marked in
 * client_read_only_metadata too: at create, and for an older tenant on its next sync. It is still never mirrored.
 */
const tenantWorld = () => {
  const w = stackWorld()
  const tenants = new Set<string>()
  const visible = new Set<string>()
  const marks: Array<string> = []
  const base = w.fake.getTeam
  const fake = {
    ...w.fake,
    getTeam: async (t: string) => {
      const team = await base(t)
      return team && tenants.has(t) ? { ...team, vm_personal_tenant: true, vm_personal_tenant_visible: visible.has(t) } : team
    },
    markVmPersonalTenantVisible: async (t: string) => {
      marks.push(t)
      if (!tenants.has(t)) return false
      visible.add(t)
      return true
    }
  }
  return { w: { ...w, fake }, tenants, visible, marks }
}

describe("a cmux VM personal tenant is marked for clients and never mirrored", { timeout: 60_000 }, () => {
  it("an older tenant (Leo's shape: the owner its only member) is marked on its next sync, once", async () => {
    const t = tenantWorld()
    const stackTeam = crypto.randomUUID()
    const owner = crypto.randomUUID()
    await useStack(stackTeam, t.w)
    t.w.teams.set(stackTeam, "Personal")
    t.w.members.set(`${stackTeam}:${owner}`, "Owner")
    t.tenants.add(stackTeam)
    const first = await deliver("team.updated", { id: stackTeam, display_name: "Personal", profile_image_url: null, created_at_millis: Date.now() })
    expect(first.body).toMatchObject({ ok: true, outcome: "vm_personal_tenant_marked" })
    const again = await deliver("team.updated", { id: stackTeam, display_name: "Personal", profile_image_url: null, created_at_millis: Date.now() })
    expect(again.body).toMatchObject({ ok: true, outcome: "vm_personal_tenant_ignored" })
    expect(t.marks).toEqual([stackTeam])
    expect((await teamState(teamIdOf(stackTeam))).team).toBeNull()
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, owner))).toBeNull()
  })

  it("a tenant whose mark fails stays ignored, and the next sync tries again", async () => {
    const t = tenantWorld()
    const stackTeam = crypto.randomUUID()
    await useStack(stackTeam, t.w)
    t.w.teams.set(stackTeam, "Personal")
    t.tenants.add(stackTeam)
    const fake = t.w.fake as { markVmPersonalTenantVisible: (s: string) => Promise<boolean> }
    const real = fake.markVmPersonalTenantVisible
    fake.markVmPersonalTenantVisible = async () => { throw new Error("stack PATCH returned 503") }
    expect((await deliver("team.updated", { id: stackTeam, display_name: "Personal", profile_image_url: null, created_at_millis: Date.now() })).body).toMatchObject({ ok: true, outcome: "vm_personal_tenant_ignored" })
    fake.markVmPersonalTenantVisible = real
    expect((await deliver("team.updated", { id: stackTeam, display_name: "Personal", profile_image_url: null, created_at_millis: Date.now() })).body).toMatchObject({ ok: true, outcome: "vm_personal_tenant_marked" })
  })

  it("a real team is mirrored and never marked", async () => {
    const t = tenantWorld()
    const stackTeam = crypto.randomUUID()
    const person = crypto.randomUUID()
    await useStack(stackTeam, t.w)
    t.w.teams.set(stackTeam, "Acme")
    t.w.members.set(`${stackTeam}:${person}`, "Person")
    expect((await deliver("team.updated", { id: stackTeam, display_name: "Acme", profile_image_url: null, created_at_millis: Date.now() })).body).toMatchObject({ ok: true })
    expect(t.marks).toEqual([])
    expect(await memberRow(teamIdOf(stackTeam), userIdFor(PROJECT, person))).toMatchObject({ display_name: "Person" })
  })
})

type Sent = { method: string; path: string; body: any }
const fakeStack = (team: { server_metadata?: unknown; client_read_only_metadata?: unknown } | null) => {
  const sent: Array<Sent> = []
  const http = async (r: Request) => {
    const path = new URL(r.url).pathname.replace(/^\/api\/v1/, "")
    const body: any = r.method === "GET" ? undefined : await r.json().catch(() => undefined)
    sent.push({ method: r.method, path, body })
    if (r.method === "GET") return team === null ? new Response("{}", { status: 404, headers: { "x-stack-known-error": "TEAM_NOT_FOUND" } }) : Response.json({ display_name: "Personal", ...team })
    if (r.method === "PATCH") { if (team) team.client_read_only_metadata = body.client_read_only_metadata; return Response.json({}) }
    if (r.method === "POST" && path === "/teams") return Response.json({ id: crypto.randomUUID(), server_metadata: body.server_metadata })
    return Response.json({})
  }
  return { sent, http }
}
const env = { STACK_SECRET_SERVER_KEY: "sk", STACK_PROJECT_ID: PROJECT } as never

describe("stackServer.markVmPersonalTenantVisible", () => {
  it("adds the client mark to a tenant, keeps its other read-only keys, and is a no-op the second time", async () => {
    const team = { server_metadata: { cmuxVmPersonalTenant: { version: 1 } }, client_read_only_metadata: { cmuxPlan: "pro" } }
    const f = fakeStack(team)
    const s = stackServer(env, f.http)!
    expect(await s.markVmPersonalTenantVisible!("t1")).toBe(true)
    expect(team.client_read_only_metadata).toEqual({ cmuxPlan: "pro", cmuxVmPersonalTenant: true })
    expect(await s.markVmPersonalTenantVisible!("t1")).toBe(true)
    expect(f.sent.filter((x) => x.method === "PATCH")).toHaveLength(1)
    expect((await s.getTeam("t1"))?.vm_personal_tenant_visible).toBe(true)
  })

  it("never writes a team whose server metadata has no tenant marker, or a team that is gone", async () => {
    const real = fakeStack({ server_metadata: { other: 1 }, client_read_only_metadata: { cmuxPlan: "team" } })
    expect(await stackServer(env, real.http)!.markVmPersonalTenantVisible!("t2")).toBe(false)
    expect(real.sent.filter((x) => x.method === "PATCH")).toHaveLength(0)
    const gone = fakeStack(null)
    expect(await stackServer(env, gone.http)!.markVmPersonalTenantVisible!("t3")).toBe(false)
    expect(gone.sent.filter((x) => x.method === "PATCH")).toHaveLength(0)
  })
})

describe("a new VM personal tenant is marked for clients at create", () => {
  it("POST /teams carries the client mark beside the server marker", async () => {
    const f = fakeStack(null)
    const stack = personalTenantStack(env, f.http)!
    const marker = { version: 1 as const, project: PROJECT, team: "team_x", user: "u", stack_user: crypto.randomUUID(), nonce: "n" }
    await stack.create(marker).catch(() => undefined)
    const post = f.sent.find((x) => x.method === "POST" && x.path === "/teams")!
    expect(post.body.client_read_only_metadata).toEqual({ cmuxVmPersonalTenant: true })
    expect(post.body.server_metadata.cmuxVmPersonalTenant).toMatchObject({ nonce: "n" })
  })
})
