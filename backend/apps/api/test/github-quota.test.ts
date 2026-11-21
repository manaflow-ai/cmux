import type { Principal } from "@cmux/ownership"
import { describe, expect, it, vi } from "vitest"
import { githubRepos, githubToken, type LedgerHost } from "../src/integrations/github-tokens.ts"
import { failed, ProviderError } from "../src/integrations/provider-core.ts"
import { forgetInstallationToken, github } from "../src/integrations/providers.ts"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, ok, read, testEnv, token } from "./github-token-support.ts"

/**
 * GitHub API quota on the server side of Connect and the token paths. The fake GitHub counts every call, so each
 * case states how many GitHub calls one operation costs, and a rate limit from GitHub is a named wait that never
 * marks the connection or reads as "connect GitHub".
 */

const doOf = (team: string) => testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
const githubConnection = async (session: string) => (await read(session, "integration.list")).body.value.connections.find((c: any) => c.provider === "github")

describe("GitHub API quota", { timeout: 60_000 }, () => {
  it("one GitHub mint for concurrent asks of one token, none while it is reused; one App JWT across mints", async () => {
    const a = await signedInWithInstall("gh-quota-mint", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const linkMints = gh.mints().length
    const ask = { team: a.team, repo: "acme/web", permissions: { contents: "read" } }
    // Five machines' git asking at once for the same repository and permissions: one GitHub call.
    const answers = await Promise.all(Array.from({ length: 5 }, () => token(a.installToken, ask)))
    expect(answers.map((r) => r.status)).toEqual([200, 200, 200, 200, 200])
    expect(new Set(answers.map((r) => r.body.token_id)).size).toBe(1)
    expect(gh.mints().length - linkMints).toBe(1)
    // Twenty more asks within the reuse window: no GitHub call.
    for (let i = 0; i < 20; i++) expect((await token(a.installToken, ask)).status).toBe(200)
    expect(gh.mints().length - linkMints).toBe(1)

    // Mints minutes apart sign with the same App JWT (it lives nine minutes), not a fresh one each.
    await inDO(doOf(a.team), async (instance) => {
      const start = Date.now()
      const clock = vi.spyOn(Date, "now").mockReturnValue(start)
      try {
        const p: Principal = { identity: `user:${a.user}`, kind: "session", user: a.user, team: a.team }
        const h: LedgerHost = { ...instance.ledgerHost(a.team), state: () => instance.boundEngine.currentState }
        const before = gh.mints().length
        for (const [i, repo] of ["acme/api", "acme/web"].entries()) {
          clock.mockReturnValue(start + i * 120_000)
          expect(await githubToken(h, p, { repo, permissions: { issues: "read" } }, start + i * 120_000)).toMatchObject({ ok: true })
        }
        const jwts = gh.mints().slice(before).map((c) => c.auth)
        expect(jwts).toHaveLength(2)
        expect(jwts[0]).toBe(jwts[1])
      } finally {
        clock.mockRestore()
      }
    })
  })

  it("repository listing: concurrent cold listings share one discovery mint, and an unchanged page is revalidated (304, no quota)", async () => {
    const a = await signedInWithInstall("gh-quota-repos", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    await inDO(doOf(a.team), async (instance) => {
      const p: Principal = { identity: `user:${a.user}`, kind: "session", user: a.user, team: a.team }
      const h: LedgerHost = { ...instance.ledgerHost(a.team), state: () => instance.boundEngine.currentState }
      const etag = `W/"${crypto.randomUUID()}"`
      gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ token: `ghs_quota_${crypto.randomUUID()}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { metadata: "read" } }, 201)
      let notModified = 0
      gh.routes["https://api.github.com/installation/repositories"] = (req) =>
        req.headers.get("if-none-match") === etag
          ? (notModified++, new Response(null, { status: 304, headers: { etag, "x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4999" } }))
          : new Response(JSON.stringify({ total_count: 1, repositories: [{ full_name: "acme/web", private: true }] }), { status: 200, headers: { "content-type": "application/json", etag, "x-ratelimit-limit": "5000", "x-ratelimit-remaining": "4998", "x-ratelimit-reset": String(Math.floor(Date.now() / 1000) + 3600) } })
      const listings = () => gh.calls.filter((c) => c.url.includes("/installation/repositories?"))
      const logs = vi.spyOn(console, "log")
      try {
        expect(await githubRepos(h, p, {})).toMatchObject({ ok: true, value: { repos: [{ full_name: "acme/web" }] } })
        // The installation's headroom reaches the log (Axiom) from the listing answer.
        const headroom = logs.mock.calls.map((c) => String(c[0])).filter((l) => l.includes('"msg":"github.ratelimit"')).map((l) => JSON.parse(l))
        expect(headroom).toContainEqual(expect.objectContaining({ installation: 99, auth: "installation", op: "list_repos", limit: 5000, remaining: 4998 }))
      } finally {
        logs.mockRestore()
      }
      // A cold cache (the discovery token dropped): three pickers opening at once cost one mint, not three.
      forgetInstallationToken(99, listings().at(-1)!.auth!.slice("Bearer ".length))
      const mints = gh.mints().length
      const calls = listings().length
      const three = await Promise.all([githubRepos(h, p, {}), githubRepos(h, p, {}), githubRepos(h, p, {})])
      expect(three.map((r) => r.ok)).toEqual([true, true, true])
      expect(three.every((r) => r.ok && r.value.repos[0]?.full_name === "acme/web")).toBe(true)
      expect(gh.mints().length - mints).toBe(1)
      // Each page read asks If-None-Match and GitHub answers 304, which spends none of the installation's limit.
      expect([listings().length - calls, notModified]).toEqual([3, 3])
    })
  })

  it("status reads GitHub once a day per installation and never mints", async () => {
    const a = await signedInWithInstall("gh-quota-status", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" } })
    const calls = gh.calls.length
    for (let i = 0; i < 10; i++) {
      const res = await worker.fetch(`https://api.test/v1/integrations/github/status?team=${a.team}`, { headers: { authorization: `Bearer ${a.session}` } })
      expect(res.status).toBe(200)
    }
    const used = gh.calls.slice(calls)
    expect([used.length, used.filter((c) => c.url.endsWith("/access_tokens")).length]).toEqual([1, 0])
  })

  it.each([
    ["a secondary rate limit with no headers", 403, {}, "You have exceeded a secondary rate limit. Please wait a few minutes before you try again.", 60],
    ["abuse detection with Retry-After", 403, { "retry-after": "90" }, "You have triggered an abuse detection mechanism.", 90],
    ["an exhausted primary limit", 403, { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "__RESET_45__" }, "API rate limit exceeded for installation ID 99.", 45],
    ["a 429", 429, { "retry-after": "7" }, "", 7],
  ] as const)("GitHub answering a mint with %s is a named wait, never needs_reauth or a refusal, and the connection stays active", async (_name, status, headers, message, wait) => {
    const a = await signedInWithInstall(`gh-quota-limit-${status}-${wait}`, "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const resolved = () => Object.fromEntries(Object.entries(headers).map(([k, v]) => [k, v === "__RESET_45__" ? String(Math.floor(Date.now() / 1000) + 45) : v]))
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => new Response(JSON.stringify({ message }), { status, headers: resolved() })
    const res = await worker.fetch("https://api.test/v1/integrations/github/token", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${a.installToken}` }, body: JSON.stringify({ team: a.team, repo: "acme/web", permissions: { contents: "read" } }) })
    const body = (await res.json()) as any
    expect([res.status, body.error.code]).toEqual([429, "rate_limited"])
    expect(Math.abs(body.retry_after - wait)).toBeLessThanOrEqual(1)
    expect(body.error.message).toBe(`GitHub is rate limiting cmux; try again in ${body.retry_after} s`)
    expect(res.headers.get("retry-after")).toBe(String(body.retry_after))
    expect(await githubConnection(a.session)).toMatchObject({ status: "active" })

    // The repository listing reads the same answer the same way (its discovery mint, then its page read).
    await inDO(doOf(a.team), async (instance) => {
      const needsReauth = vi.fn()
      const h: LedgerHost = { ...instance.ledgerHost(a.team), state: () => instance.boundEngine.currentState, needsReauth }
      const p: Principal = { identity: `user:${a.user}`, kind: "session", user: a.user, team: a.team }
      gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ token: `ghs_lim_${crypto.randomUUID()}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { metadata: "read" } }, 201)
      gh.routes["https://api.github.com/installation/repositories"] = () => new Response(JSON.stringify({ message }), { status, headers: resolved() })
      const listed = await githubRepos({ ...h, needsReauth }, p, {})
      expect(listed).toMatchObject({ ok: false, status: 429, code: "rate_limited" })
      expect(!listed.ok && listed.message).toMatch(/^GitHub is rate limiting cmux; try again in \d+ s$/)
      expect(needsReauth).not.toHaveBeenCalled()
    })
    expect(await githubConnection(a.session)).toMatchObject({ status: "active" })
  })

  it("provider calls and Connect: a rate limit is a retryable wait, a 401 still asks for a relink", async () => {
    const limited = failed("github", new Response("{}", { status: 403, headers: { "x-ratelimit-remaining": "0", "retry-after": "30" } }), "comment", true)
    expect([limited.code, limited.retryable, limited.message]).toEqual(["provider.error", true, "GitHub is rate limiting cmux; try again in 30 s"])
    expect(failed("github", new Response("{}", { status: 401 }), "comment").code).toBe("needs_reauth")
    expect(failed("github", new Response("{}", { status: 403 }), "comment")).toMatchObject({ code: "provider.error", retryable: false })

    // Finishing Connect while GitHub rate limits the code exchange: a wait to retry, not an invalid link.
    const http = async (req: Request) =>
      req.url.startsWith("https://github.com/login/oauth/access_token") ? new Response(JSON.stringify({ message: "rate limited" }), { status: 429, headers: { "retry-after": "12" } }) : new Response("not found", { status: 404 })
    const refused = await github.complete(testEnv as any, http, { code: "c", installation_id: "99", setup_action: "install", redirectUri: "https://api.test/cb", policy: { githubScope: "linking_user_repos", requireOrgAdmin: false }, connection: "conn_x", state: "s", scopes_requested: [] }).catch((e: unknown) => e)
    expect(refused).toBeInstanceOf(ProviderError)
    expect([(refused as ProviderError).code, (refused as ProviderError).retryable, (refused as ProviderError).message]).toEqual(["provider.error", true, "GitHub is rate limiting cmux; try again in 12 s"])

    // Concurrent comments on one repository share one mint of the comment token.
    let mints = 0
    const repo = `acme/quota-${crypto.randomUUID().slice(0, 8)}`
    const commentHttp = async (req: Request) => {
      if (req.url.endsWith("/access_tokens")) {
        mints++
        await new Promise((r) => setTimeout(r, 20))
        return new Response(JSON.stringify({ token: `ghs_c_${crypto.randomUUID()}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { issues: "write", metadata: "read" } }), { status: 201 })
      }
      const issue = /\/issues\/(\d+)\/comments$/.exec(new URL(req.url).pathname)![1]
      return new Response(JSON.stringify({ id: 1, html_url: `https://github.com/${repo}/issues/${issue}#issuecomment-1` }), { status: 201 })
    }
    const cred = { kind: "github_installation" as const, installation_id: 99 }
    const posted = await Promise.all([1, 2, 3].map((issue) => github.call(testEnv as any, commentHttp, cred, "github.issue.comment", { repo, issue, body: "hi" }).then(() => "ok", (e: unknown) => String(e))))
    expect([posted, mints]).toEqual([["ok", "ok", "ok"], 1])
  })
})
