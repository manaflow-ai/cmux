import { describe, expect, it } from "vitest"
import { settlePolicy } from "./integration-policy-settle.ts"
import { linkGitHub } from "./github-token-support.ts"
import { call, deliver, mirroredTeam } from "./team-stack-support.ts"
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

    // A repository on an owner the person never connected is still the team's refusal, not a token.
    const other = await mint(t.token, { team: t.team, repo: "elsewhere/app", permissions: { contents: "read" } })
    expect(other.status).toBe(404)
    expect(other.body.error.code).toBe("integration.not_found")

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
})
