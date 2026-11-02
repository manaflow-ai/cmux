import { env } from "cloudflare:workers"
import { expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import { personalTenantStack, PersonalTenantIdentityError, PERSONAL_TENANT_METADATA_KEY } from "../src/team-vm-api-personal-stack.ts"
import type { PersonalTenantMarker } from "../src/team-vm-api-personal-store.ts"

const project = "test-project", stackUser = "5d88e1e9-e265-4da8-893c-c0d05a252bc3", tenant = "ca4bc6ed-acdd-47e4-9753-4d1bb37b72c4"
const user = userIdFor(project, stackUser)
const marker: PersonalTenantMarker = { version: 1, project, team: personalTeamIdFor(user), user, stack_user: stackUser, nonce: "b4104da5-b473-4a14-9455-e2c6b671ec3e" }
const e = { ...(env as Env), STACK_PROJECT_ID: project, STACK_SECRET_SERVER_KEY: "test-server-secret" }
const team = { id: tenant, server_metadata: { cmuxVmPersonalTenant: marker } }

it("exports the server metadata key used to identify personal VM tenants", () => {
  expect(PERSONAL_TENANT_METADATA_KEY).toBe("cmuxVmPersonalTenant")
})

it("creates the team with server metadata and no creator, then adds the owner as a plain member", async () => {
  const calls: Request[] = []
  const stack = personalTenantStack(e, async (r) => {
    calls.push(r.clone())
    expect(r.redirect).toBe("manual")
    expect(r.headers.get("x-stack-access-type")).toBe("server")
    expect(r.headers.get("x-stack-project-id")).toBe(project)
    expect(r.headers.get("x-stack-secret-server-key")).toBe(e.STACK_SECRET_SERVER_KEY)
    if (calls.length === 1) {
      // No creator_user_id: Stack would grant the creator its admin defaults, including invites.
      expect(await r.json()).toEqual({ display_name: "Personal", server_metadata: { cmuxVmPersonalTenant: marker } })
      return Response.json(team)
    }
    expect(await r.json()).toEqual({})
    return Response.json({ team_id: tenant, user_id: stackUser })
  })!
  expect(await stack.create(marker)).toEqual({ id: tenant, marker })
  expect(calls.map((r) => `${r.method} ${r.url}`)).toEqual(["POST https://api.stack-auth.com/api/v1/teams", `POST https://api.stack-auth.com/api/v1/team-memberships/${tenant}/${stackUser}`])
})

it("deletes a created team whose owner could not be added, so a later create may start clean", async () => {
  for (const removed of [true, false]) {
    const calls: string[] = []
    const stack = personalTenantStack(e, async (r) => {
      calls.push(`${r.method} ${new URL(r.url).pathname}`)
      if (r.method === "POST" && calls.length === 1) return Response.json(team)
      if (r.method === "POST") return Response.json({}, { status: 503 })
      return removed ? Response.json({}) : Response.json({}, { status: 503 })
    })!
    const error: unknown = await stack.create(marker).catch((value: unknown) => value)
    expect(error).toBeInstanceOf(PersonalTenantIdentityError)
    if (error instanceof PersonalTenantIdentityError) expect(error.definitelyUnsent).toBe(removed)
    expect(calls).toEqual(["POST /api/v1/teams", `POST /api/v1/team-memberships/${tenant}/${stackUser}`, `DELETE /api/v1/teams/${tenant}`])
  }
})

it("ignores client-selected metadata and follows all discovery and membership pages", async () => {
  const stack = personalTenantStack(e, async (r) => {
    const url = new URL(r.url)
    if (url.pathname.endsWith("/teams")) {
      expect(url.searchParams.get("limit")).toBe("100")
      expect(url.searchParams.get("user_id")).toBe(stackUser)
      return Response.json(url.searchParams.has("cursor") ? { items: [team], pagination: { next_cursor: null } } : { items: [{ id: tenant, client_metadata: { cmuxVmPersonalTenant: marker }, client_read_only_metadata: { cmuxVmPersonalTenant: marker } }], pagination: { next_cursor: "next" } })
    }
    // The production members read (stack-server.ts listTeamMembers): team_id alone. Stack refuses `limit` here (400 SCHEMA_ERROR).
    expect(r.method).toBe("GET")
    if (!url.searchParams.has("cursor")) expect(r.url).toBe(`https://api.stack-auth.com/api/v1/team-member-profiles?team_id=${tenant}`)
    expect([...url.searchParams.keys()].filter((k) => k !== "cursor")).toEqual(["team_id"])
    return Response.json(url.searchParams.has("cursor") ? { items: [{ user_id: "another-user" }], pagination: { next_cursor: null } } : { items: [{ user_id: stackUser }], pagination: { next_cursor: "members-next" } })
  })!
  expect(await stack.find(marker)).toEqual([{ id: tenant, marker }])
  expect(await stack.members(tenant)).toEqual([stackUser, "another-user"])
})

it("rejects mismatched server receipts, repeated cursors and unreadable lists", async () => {
  for (const body of [
    { items: [{ ...team, server_metadata: { cmuxVmPersonalTenant: { ...marker, project: "other-project" } } }] },
    { items: [], pagination: { next_cursor: "same" } },
    { items: "invalid" }
  ]) {
    const stack = personalTenantStack(e, async () => Response.json(body))!
    await expect(stack.find(marker)).rejects.toThrow("identity service unavailable")
  }
})

it("classifies only definitive rejections as safe to retry and never leaks answer bodies", async () => {
  for (const status of [302, 401, 429, 503]) {
    let calls = 0
    const stack = personalTenantStack(e, async () => { calls++; return Response.json({ secret: e.STACK_SECRET_SERVER_KEY, private: marker.nonce }, { status }) })!
    const error: unknown = await stack.create(marker).catch((value: unknown) => value)
    expect(error).toBeInstanceOf(PersonalTenantIdentityError)
    if (error instanceof PersonalTenantIdentityError) expect(error.definitelyUnsent).toBe(status === 401 || status === 429)
    expect(String(error)).not.toContain(e.STACK_SECRET_SERVER_KEY)
    expect(String(error)).not.toContain(marker.nonce)
    expect(calls).toBe(1)
  }
  const broken = personalTenantStack(e, async () => new Response("private malformed response", { headers: { "content-type": "application/json" } }))!
  await expect(broken.create(marker)).rejects.toThrow("identity service unavailable")
})

it("names the failed call, its status and Stack's known-error code, and nothing from the body", async () => {
  const stack = personalTenantStack(e, async () => Response.json({ secret: e.STACK_SECRET_SERVER_KEY }, { status: 403, headers: { "x-stack-known-error": "INSUFFICIENT_ACCESS_TYPE" } }))!
  const error: unknown = await stack.create(marker).catch((value: unknown) => value)
  expect(error).toBeInstanceOf(PersonalTenantIdentityError)
  expect((error as PersonalTenantIdentityError).failure).toEqual({ call: "create", status: 403, code: "INSUFFICIENT_ACCESS_TYPE" })
  expect(JSON.stringify((error as PersonalTenantIdentityError).failure)).not.toContain(e.STACK_SECRET_SERVER_KEY)
  const joined = personalTenantStack(e, async (r) => r.method === "POST" && new URL(r.url).pathname.endsWith("/teams") ? Response.json(team) : r.method === "POST" ? Response.json({}, { status: 400, headers: { "x-stack-known-error": "not a code; " + e.STACK_SECRET_SERVER_KEY } }) : Response.json({}))!
  expect(((await joined.create(marker).catch((value: unknown) => value)) as PersonalTenantIdentityError).failure).toEqual({ call: "join", status: 400 })
  const unreachable = personalTenantStack(e, async () => { throw new TypeError("network") })!
  expect(((await unreachable.find(marker).catch((value: unknown) => value)) as PersonalTenantIdentityError).failure).toEqual({ call: "find", cause: "network" })
})
