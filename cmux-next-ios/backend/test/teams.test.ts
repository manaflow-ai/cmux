import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { Caller } from "../src/auth.ts"
import type { Env } from "../src/env.ts"
import { createTeam } from "../src/stack.ts"
import { call, DEV_PROJECT, PROD_PROJECT, token } from "./helpers.ts"

const STACK = "https://api.stack-auth.com/api/v1"
const TEAM_ID = "33333333-3333-4333-8333-333333333333"

type StackRequest = { method: string; url: string; body: string | null; serverKey: string | null }

/** A fake Stack server API: creates a team, grants permissions, deletes teams; `failGrant` refuses the grant. */
const fakeStack = (opts: { failGrant?: "status" | "network"; failDelete?: boolean } = {}) => {
  const requests: Array<StackRequest> = []
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    const body = request.method === "GET" || request.method === "DELETE" ? null : await request.text()
    requests.push({ method: request.method, url: request.url, body, serverKey: request.headers.get("x-stack-secret-server-key") })
    if (request.method === "POST" && request.url === `${STACK}/teams`) {
      const { display_name } = JSON.parse(body ?? "{}") as { display_name: string }
      return Response.json({ id: TEAM_ID, display_name }, { status: 201 })
    }
    if (request.method === "POST" && request.url.startsWith(`${STACK}/team-permissions/`)) {
      if (opts.failGrant === "network") throw new TypeError("network down")
      if (opts.failGrant === "status") return new Response("{}", { status: 500 })
      return Response.json({ id: "team_admin" }, { status: 201 })
    }
    if (request.method === "DELETE" && request.url === `${STACK}/teams/${TEAM_ID}`) {
      return opts.failDelete ? new Response("{}", { status: 500 }) : Response.json({ success: true })
    }
    return new Response("unexpected", { status: 599 })
  }
  return { requests, fetcher }
}

const caller = (userId: string): Caller => ({ userId, projectId: DEV_PROJECT, token: "unused" })

afterEach(() => {
  vi.restoreAllMocks()
})

// Full verify D1 (2026-10-19): the phone created teams with Stack's client API, which both Stack
// projects refuse (client_team_creation_enabled is false), so no team ever appeared. The Worker
// creates the team with the project's server key and makes the caller its creator and member.
describe("POST /v1/teams", () => {
  it("creates a team for the caller, grants them team_admin, and returns its id and name", async () => {
    const stack = fakeStack()
    vi.spyOn(globalThis, "fetch").mockImplementation(stack.fetcher)
    const r = await call("POST", "/v1/teams", await token("alice"), { name: "  fv team  " })
    expect(r.status).toBe(200)
    expect(r.json.team).toEqual({ id: TEAM_ID, name: "fv team" })
    expect(stack.requests.map((q) => `${q.method} ${q.url}`)).toEqual([
      `POST ${STACK}/teams`,
      `POST ${STACK}/team-permissions/${TEAM_ID}/alice/team_admin`
    ])
    expect(JSON.parse(stack.requests[0]!.body!)).toEqual({ display_name: "fv team", creator_user_id: "alice" })
    expect(stack.requests.every((q) => q.serverKey === "test-server-key")).toBe(true)
  })

  it("deletes the team and fails when the admin grant fails", async () => {
    const stack = fakeStack({ failGrant: "status" })
    vi.spyOn(globalThis, "fetch").mockImplementation(stack.fetcher)
    const r = await call("POST", "/v1/teams", await token("alice"), { name: "orphan" })
    expect(r.status).toBe(502)
    expect(r.json.error.code).toBe("team_create_failed")
    expect(stack.requests.map((q) => `${q.method} ${q.url}`)).toEqual([
      `POST ${STACK}/teams`,
      `POST ${STACK}/team-permissions/${TEAM_ID}/alice/team_admin`,
      `DELETE ${STACK}/teams/${TEAM_ID}`
    ])
  })

  it("needs a name of at most 64 characters", async () => {
    const tok = await token("alice")
    expect((await call("POST", "/v1/teams", tok, {})).status).toBe(400)
    expect((await call("POST", "/v1/teams", tok, { name: "   " })).status).toBe(400)
    expect((await call("POST", "/v1/teams", tok, { name: "x".repeat(65) })).status).toBe(400)
    expect((await call("POST", "/v1/teams", tok, { name: "a\nb" })).status).toBe(400)
  })

  it("says so when this Worker cannot create teams for the caller's project", async () => {
    const stack = fakeStack()
    vi.spyOn(globalThis, "fetch").mockImplementation(stack.fetcher)
    const r = await call("POST", "/v1/teams", await token("pat", { project: PROD_PROJECT }), { name: "Prod team" })
    expect(r.status).toBe(503)
    expect(r.json.error.code).toBe("team_creation_unavailable")
    expect(stack.requests).toEqual([])
  })

  it("needs a signed-in caller", async () => {
    expect((await call("POST", "/v1/teams", undefined, { name: "x" })).status).toBe(401)
  })
})

describe("createTeam", () => {
  const testEnv = env as unknown as Env

  it("rolls the team back when the grant request cannot reach Stack", async () => {
    const stack = fakeStack({ failGrant: "network" })
    const r = await createTeam(testEnv, caller("bob"), "net", stack.fetcher)
    expect(r).toEqual({ ok: false, status: 502, code: "team_admin_grant_failed" })
    expect(stack.requests.at(-1)).toMatchObject({ method: "DELETE", url: `${STACK}/teams/${TEAM_ID}` })
  })

  it("still reports the grant failure when the rollback delete fails too", async () => {
    const stack = fakeStack({ failGrant: "status", failDelete: true })
    vi.spyOn(console, "error").mockImplementation(() => {})
    const r = await createTeam(testEnv, caller("bob"), "both", stack.fetcher)
    expect(r.ok).toBe(false)
    expect(stack.requests.map((q) => q.method)).toEqual(["POST", "POST", "DELETE"])
  })
})
