import { describe, expect, it } from "vitest"
import { settlePolicy } from "./integration-policy-settle.ts"
import { fakeGitHub, inDO, linkGitHub, testEnv } from "./github-token-support.ts"
import { call, deliver, mirroredTeam, teamIdOf, useStack } from "./team-stack-support.ts"
import { worker } from "./cloud-bind-support.ts"

/**
 * cmux#55104: a person links the cmux GitHub App once, in their personal team (Settings with no Stack team selected),
 * and their Cloud machines run in their selected Stack team. The Stack team's ConnectionDO holds none of their
 * connections, so the machine's token ask answered `integration.not_found` and the clone ended `seed.needs_github`
 * ("Connect GitHub so Cloud can clone …") though the App they installed covers the repository. The token, status and
 * repository routes now fall back to the person's own connections in their personal team, under the Stack team's policy.
 * GitHub is faked (github-token-support.ts: installation 99 on acme, covering acme/web and acme/api).
 */
const get = async (path: string, bearer: string) => {
  const res = await worker.fetch(`https://api.test${path}`, { headers: { authorization: `Bearer ${bearer}` } })
  return { status: res.status, body: (await res.json()) as any }
}
const mint = async (bearer: string, body: unknown) => {
  const res = await worker.fetch("https://api.test/v1/integrations/github/token", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${bearer}` }, body: JSON.stringify(body) })
  return { status: res.status, body: (await res.json()) as any }
}

describe("GitHub tokens from the person's own connection in another team (cmux#55104)", { timeout: 60_000 }, () => {
  it("a Stack team with no GitHub connection mints, reports and lists from the member's personal-team connection, under the Stack team's policy", async () => {
    const t = await mirroredTeam("Manaflow")
    // Owner of the Stack team, so the test can set its policy below.
    t.w.perms.set(`${t.stackTeam}:${t.stackUser}`, ["$delete_team"])
    expect((await deliver("team_permission.created", { id: "$delete_team", team_id: t.stackTeam, user_id: t.stackUser })).status).toBe(200)
    // Linked with no x-cmux-team: the connection lands in the person's personal team, not the Stack team.
    const { gh } = await linkGitHub(t.token, (await call(t.token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.value.personal_team)

    // The Stack team's own ConnectionDO has no GitHub connection; before the fallback this was 404 integration.not_found.
    const token = await mint(t.token, { team: t.team, repo: "acme/web", permissions: { contents: "read" } })
    expect(token.status, JSON.stringify(token.body)).toBe(200)
    expect(token.body).toMatchObject({ repo: "acme/web", permissions: { contents: "read" } })
    expect(gh.mints().length).toBe(1)

    // A repository on an owner the person never connected is no token: the App missing on that owner (install it there),
    // never "connect GitHub", which would only reopen the install the person already has.
    const other = await mint(t.token, { team: t.team, repo: "elsewhere/app", permissions: { contents: "read" } })
    expect(other.status).toBe(403)
    expect(other.body.error).toMatchObject({ code: "policy.denied", reason: "owner_not_connected" })

    // A repository the person's connection leaves out answers why (their installation), not "no connection".
    const left = await mint(t.token, { team: t.team, repo: "acme/secret", permissions: { contents: "read" } })
    expect(left.status).toBe(403)
    expect(left.body.error).toMatchObject({ code: "policy.denied", reason: "repo_not_granted" })

    // The status the app reads before a Cloud start (CloudGitHubApp): ready, from the person's own connection.
    const status = await get(`/v1/integrations/github/status?team=${t.team}`, t.token)
    expect(status.status).toBe(200)
    expect(status.body.connection).toMatchObject({ account: "acme", status: "active" })

    // The folder menu's repositories, from the same connection.
    gh.routes["https://api.github.com/installation/repositories"] = () =>
      new Response(JSON.stringify({ total_count: 2, repositories: [{ full_name: "acme/web", private: true }, { full_name: "acme/api", private: true }] }), { status: 200, headers: { "content-type": "application/json" } })
    const repos = await get(`/v1/integrations/github/repos?team=${t.team}`, t.token)
    expect(repos.status, JSON.stringify(repos.body)).toBe(200)
    expect(repos.body.repos.map((r: any) => r.full_name).sort()).toEqual(["acme/api", "acme/web"])

    // The Stack team's policy governs the fallback: an allowlist without acme/web refuses it.
    const inTeam = (bearer: string, name: string, params: unknown) =>
      call(bearer, "/v1/ops", { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }, t.team).then((r) => ({ json: r.body }))
    const readInTeam = (bearer: string, name: string, params: unknown) => call(bearer, "/v1/read", { op: name, params }, t.team).then((r) => ({ json: r.body }))
    const set = await settlePolicy(inTeam, readInTeam, t.token, t.team, { github: { repo_allowlist: ["acme/api"] } })
    expect(set.json.ok, JSON.stringify(set.json)).toBe(true)
    const refused = await mint(t.token, { team: t.team, repo: "acme/web", permissions: { contents: "read" } })
    expect(refused.status).toBe(403)
    expect(refused.body.error).toMatchObject({ code: "policy.denied", reason: "repo_not_allowed" })
    expect((await mint(t.token, { team: t.team, repo: "acme/api", permissions: { contents: "read" } })).status).toBe(200)
  })
  it("a connection linked while another Stack team was active answers a Cloud machine's team too (install in team A, clone in team B)", async () => {
    const a = await mirroredTeam("AUSTIN")
    // The same person is a member of a second Stack team, where their Cloud machine runs.
    const stackB = crypto.randomUUID()
    await useStack(stackB, a.w)
    a.w.teams.set(stackB, "cmux")
    a.w.members.set(`${stackB}:${a.stackUser}`, "Aziz")
    expect((await deliver("team.created", { id: stackB, display_name: "cmux", profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
    expect((await deliver("team_membership.created", { team_id: stackB, user_id: a.stackUser })).status).toBe(200)
    const teamB = teamIdOf(stackB)

    // Linked with team A selected (x-cmux-team: team A): the connection lands in team A's ConnectionDO.
    const gh = fakeGitHub()
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => void (instance.http = gh.http))
    const connect = await call(a.token, "/v1/ops", { op: "integration.connect", params: { provider: "github", sharing: "private" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, a.team)
    expect(connect.body.ok, JSON.stringify(connect.body)).toBe(true)
    const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
    const done = await call(a.token, "/v1/ops", { op: "integration.complete", params: { state, code: "c", installation_id: "99", setup_action: "install" }, idempotency_key: crypto.randomUUID(), origin: "cli" }, a.team)
    expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })

    // Team B (and the personal team) hold nothing; before the fallback walked every team this was integration.not_found.
    const token = await mint(a.token, { team: teamB, repo: "acme/web", permissions: { contents: "read" } })
    expect(token.status, JSON.stringify(token.body)).toBe(200)
    expect(token.body).toMatchObject({ repo: "acme/web" })
    expect(gh.mints().length).toBe(1)
    const status = await get(`/v1/integrations/github/status?team=${teamB}`, a.token)
    expect(status.body.connection).toMatchObject({ account: "acme", status: "active" })

    // A team the person is not a member of never reads their connections: removed from team A, team B's ask finds nothing.
    a.w.members.delete(`${a.stackTeam}:${a.stackUser}`)
    expect((await deliver("team_membership.deleted", { team_id: a.stackTeam, user_id: a.stackUser })).status).toBe(200)
    const gone = await mint(a.token, { team: teamB, repo: "acme/web", permissions: { contents: "read" } })
    expect(gone.status, JSON.stringify(gone.body)).toBe(404)
    expect(gone.body.error.code).toBe("integration.not_found")
  })

  it("the reporter's state: the App is installed only on the person's own account, the repository is an organization's (cmux#55104)", async () => {
    const t = await mirroredTeam("AUSTIN")
    const personal = (await call(t.token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.value.personal_team
    // Installation 99 is on acme (the person's own account, as installation 183460287 is on austinywang); the App is
    // not installed on the organization `manaflow`.
    const { gh } = await linkGitHub(t.token, personal)
    gh.routes["https://api.github.com/orgs/manaflow/installation"] = () => new Response("not found", { status: 404 })
    gh.routes["https://api.github.com/users/manaflow/installation"] = () => new Response("not found", { status: 404 })

    // From the Stack team (no connection) and from the personal team (the connection) alike: not "connect GitHub"
    // (integration.not_found), but the App missing on that owner, which a person fixes by installing it there.
    for (const team of [t.team, personal]) {
      const refused = await mint(t.token, { team, repo: "manaflow/hq", permissions: { contents: "read" } })
      expect(refused.status, JSON.stringify(refused.body)).toBe(403)
      expect(refused.body.error).toMatchObject({ code: "policy.denied", reason: "owner_not_connected" })
    }
    expect(gh.mints().length).toBe(0)
  })
})
