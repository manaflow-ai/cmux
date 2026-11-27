import { describe, expect, it } from "vitest"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, ok, op, testEnv, token } from "./github-token-support.ts"

/**
 * A pending GitHub App permission update (Leo, 2026-11-25: "You need to just do this and wire it up"): the App now
 * requests contents: write, an installation that has not accepted it still grants contents: read. GET /status says
 * so (`permissions_pending`, `accept_url`), and a write mint GitHub refuses answers `github.permissions_pending` with
 * the installation's settings page in `configure_url`, not a generic mint failure. GitHub is faked.
 */
const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
const ageCaches = (team: string) =>
  inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (instance) => {
    instance.ctx.storage.sql.exec(`UPDATE github_configure_pages SET checked_at = 0`)
    instance.ctx.storage.sql.exec(`UPDATE github_app_permissions SET checked_at = 0`)
  })
const NOT_GRANTED = () => ok({ message: "The permissions requested are not granted to this installation." }, 422)

describe("a pending GitHub App permission update", { timeout: 60_000 }, () => {
  it("status names it per installation with the page that accepts it, and a write mint answers github.permissions_pending", async () => {
    const a = await signedInWithInstall("gh-perms-pending", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const page = "https://github.com/organizations/acme/settings/installations/99"
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" }, permissions: { contents: "read", metadata: "read" } })
    // GET /app: the App's own requested permissions, read at runtime (the URL is exact, so it never matches /app/installations).
    let appAsks: Record<string, string> = { contents: "write", metadata: "read" }
    const routes = gh.routes as Record<string, (req: Request, body: string) => Response>
    const installationRoute = routes["https://api.github.com/app/installations/99"]!
    routes["https://api.github.com/app"] = (req, body) => (req.url === "https://api.github.com/app" ? ok({ slug: "whatever-the-app-is-named", permissions: appAsks }) : installationRoute(req, body))
    expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: page, permissions_pending: true, accept_url: page })
    // Cached: a second read asks GitHub's /app nothing more.
    const appReads = () => gh.calls.filter((c) => c.url === "https://api.github.com/app").length
    const before = appReads()
    await status(a.session, a.team)
    expect(appReads()).toBe(before)

    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = NOT_GRANTED
    const write = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })
    expect([write.status, write.body.error]).toEqual([403, { code: "github.permissions_pending", message: "GitHub needs you to accept cmux's updated permissions for acme.", configure_url: page, next: expect.stringContaining("accepts the cmux GitHub App's updated permissions") }])

    // Access the App does not request at all stays permissions_not_granted: accepting an update would not help.
    const issues = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { issues: "write" } })
    expect([issues.status, issues.body.error.code, issues.body.error.reason, issues.body.error.configure_url]).toEqual([403, "policy.denied", "permissions_not_granted", page])

    // Accepted on GitHub (installation.new_permissions_accepted drops the cached grant; here the caches age): nothing pending.
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" }, permissions: { contents: "write", metadata: "read" } })
    routes["https://api.github.com/app"] = (req, body) => (req.url === "https://api.github.com/app" ? ok({ permissions: appAsks }) : gh.routes["https://api.github.com/app/installations/99"]!(req, body))
    await ageCaches(a.team)
    expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: page, permissions_pending: false, accept_url: null })
    // An App that asks for nothing more than the grant: nothing pending either.
    appAsks = { contents: "read" }
    await ageCaches(a.team)
    expect(await status(a.session, a.team)).toMatchObject({ permissions_pending: false, accept_url: null })
  })

  it("Connect opens the installation's page that accepts a pending update, with or without a repository", async () => {
    const a = await signedInWithInstall("gh-perms-pending-connect", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const page = "https://github.com/organizations/acme/settings/installations/99"
    let granted: Record<string, string> = { contents: "read", metadata: "read" }
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" }, permissions: granted })
    // An installation on another owner the team has not linked yet (the install-or-authorize target).
    gh.routes["https://api.github.com/orgs/beta/installation"] = () => ok({ id: 55, account: { login: "beta", type: "Organization" }, permissions: { contents: "read" } })
    const installationRoute = (req: Request, body: string) => gh.routes["https://api.github.com/app/installations/99"]!(req, body)
    gh.routes["https://api.github.com/app"] = (req, body) => (req.url === "https://api.github.com/app" ? ok({ permissions: { contents: "write", metadata: "read" } }) : installationRoute(req, body))
    const connect = (params: Record<string, unknown>) => op(a.session, "integration.connect", { provider: "github", ...params }).then((r) => r.body)

    // The linked installation covers acme/web: not "connected", but its page, where "Review request" accepts the update.
    const covered = await connect({ repo: "acme/web" })
    expect(covered).toMatchObject({ ok: true, value: { authorize_url: page, permissions_pending: true } })
    expect(covered.value.connected).toBeUndefined()
    // Plain Connect / Sign in with GitHub: the same page, not the install page.
    expect((await connect({})).value).toMatchObject({ authorize_url: page, permissions_pending: true })
    // An installation on an owner the team has no connection on: its own page, not GitHub's authorize page.
    expect((await connect({ repo: "beta/app" })).value.authorize_url).toBe("https://github.com/organizations/beta/settings/installations/55")

    // Accepted: Connect is back to reuse (with a repository) and the install page (without).
    granted = { contents: "write", metadata: "read" }
    await ageCaches(a.team)
    expect((await connect({ repo: "acme/web" })).value).toMatchObject({ connected: true })
    expect(new URL((await connect({})).value.authorize_url).pathname).toMatch(/^\/apps\/[^/]+\/installations\/new/)
  })

  it("a personal account's page is /settings/installations/<id>; GET /app unknown never reads as pending", async () => {
    const a = await signedInWithInstall("gh-perms-pending-user", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" }, permissions: { contents: "read" } })
    // No /app route: GitHub's answer is unknown, so nothing is called pending.
    expect(await status(a.session, a.team)).toMatchObject({ configure_url: "https://github.com/settings/installations/99", permissions_pending: false, accept_url: null })
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = NOT_GRANTED
    const write = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })
    expect([write.body.error.code, write.body.error.reason]).toEqual(["policy.denied", "permissions_not_granted"])
    // Once GitHub's /app answers, the same refusal is the pending update, on the person's own page.
    const installationRoute = gh.routes["https://api.github.com/app/installations/99"]!
    gh.routes["https://api.github.com/app"] = (req, body) => (req.url === "https://api.github.com/app" ? ok({ permissions: { contents: "write" } }) : installationRoute(req, body))
    await ageCaches(a.team)
    const again = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })
    expect([again.body.error.code, again.body.error.configure_url]).toEqual(["github.permissions_pending", "https://github.com/settings/installations/99"])
  })
})
