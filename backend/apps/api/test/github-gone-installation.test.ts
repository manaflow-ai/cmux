import { describe, expect, it } from "vitest"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, ok, op, testEnv, token } from "./github-token-support.ts"

/**
 * cmux#55104: after the cmux GitHub App was uninstalled, GET /status kept naming the deleted installation's cached
 * settings page, the app's "Connect GitHub again" opened it, and GitHub answered 404: no way to reconnect.
 */
const hmacHex = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

const hook = async (event: string, payload: Record<string, unknown>) => {
  const body = JSON.stringify({ installation: { id: 99, account: { login: "acme" } }, ...payload })
  const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmacHex(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": event }, body })
  expect(res.status).toBe(200)
}

describe("a gone GitHub installation (cmux#55104)", { timeout: 60_000 }, () => {
  it("a gone installation names no settings page: uninstalled by webhook, or a 404 on a mint; Connect opens the install page (cmux#55104)", async () => {
    const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
    const page = "https://github.com/settings/installations/99"
    for (const how of ["webhook", "mint-404"] as const) {
      const a = await signedInWithInstall(`gh-gone-${how}`, "cli")
      const { gh } = await linkGitHub(a.session, a.team)
      gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" } })
      // Cached while the installation exists.
      expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: page })
      if (how === "webhook") await hook("installation", { action: "deleted" })
      else {
        gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "Not Found" }, 404)
        expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("needs_reauth")
      }
      // Before the fix, status kept naming the cached page, the app opened it, and GitHub answered 404.
      const after = await status(a.session, a.team)
      expect(after, how).toMatchObject({ status: "needs_reauth", configure_url: null, status_detail: how === "webhook" ? "the GitHub App was uninstalled" : "the GitHub App installation is gone" })
      // Connect for one of the account's repositories opens the App's install page, not the deleted installation.
      gh.routes["https://api.github.com/users/acme/installation"] = () => ok({ message: "Not Found" }, 404)
      gh.routes["https://api.github.com/orgs/acme/installation"] = () => ok({ message: "Not Found" }, 404)
      const connect = await op(a.session, "integration.connect", { provider: "github", repo: "acme/web" })
      expect(connect.body.ok, JSON.stringify(connect.body)).toBe(true)
      expect(String(connect.body.value.authorize_url)).toMatch(/^https:\/\/github\.com\/apps\/[^/]+\/installations\/new/)
      expect(String(connect.body.value.authorize_url)).not.toContain("/settings/installations/")
    }
  })

  it("a read finds a gone installation no webhook reported: active (cache past its hour) or suspended (asked fresh); never names its page (cmux#55104)", async () => {
    const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
    for (const how of ["active", "suspended"] as const) {
      const a = await signedInWithInstall(`gh-gone-read-${how}`, "cli")
      const { gh } = await linkGitHub(a.session, a.team)
      gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" } })
      expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: "https://github.com/settings/installations/99" })
      if (how === "suspended") {
        await hook("installation", { action: "suspend" })
        expect(await status(a.session, a.team)).toMatchObject({ status: "needs_reauth", configure_url: "https://github.com/settings/installations/99" })
      } else {
        // The cached page is past its hour.
        await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (i) => void i.ctx.storage.sql.exec(`UPDATE github_configure_pages SET checked_at = 0`))
      }
      // The installation is deleted and its webhook never arrives: GitHub answers 404 for it.
      gh.routes["https://api.github.com/app/installations/99"] = () => ok({ message: "Not Found" }, 404)
      expect(await status(a.session, a.team), how).toMatchObject({ status: "needs_reauth", configure_url: null })
      // Marked gone: later reads name no page and do not ask GitHub again.
      const asked = gh.calls.length
      expect(await status(a.session, a.team), how).toMatchObject({ status: "needs_reauth", configure_url: null })
      expect(gh.calls.length).toBe(asked)
    }
  })

  it("a reinstall is picked up: Connect after a deleted installation links the new one, and status names its page, never the old one (cmux#55104)", async () => {
    const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
    const a = await signedInWithInstall("gh-reinstall", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    await hook("installation", { action: "deleted" })
    expect(await status(a.session, a.team)).toMatchObject({ status: "needs_reauth", configure_url: null })
    // The App is installed again on the account: a new installation id.
    const NEW = 185681309
    const list = gh.routes["https://api.github.com/user/installations"]!
    gh.routes["https://api.github.com/user/installations"] = (req, body) =>
      req.url.includes(`/user/installations/${NEW}/repositories`)
        ? ok({ repositories: [{ full_name: "acme/web" }] })
        : new URL(req.url).pathname === "/user/installations"
          ? ok({ installations: [{ id: NEW, account: { login: "acme", type: "Organization" }, permissions: { contents: "write", metadata: "read" } }] })
          : list(req, body)
    gh.routes[`https://api.github.com/app/installations/${NEW}`] = () => ok({ id: NEW, account: { login: "acme", type: "Organization" } })
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ message: "Not Found" }, 404)
    const connect = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const url = String(connect.body.value.authorize_url)
    expect(url).toMatch(/^https:\/\/github\.com\/apps\/[^/]+\/installations\/new/)
    const state = new URL(url).searchParams.get("state")!
    const done = await op(a.session, "integration.complete", { state, code: "c", installation_id: String(NEW), setup_action: "install" })
    expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })
    const after = await status(a.session, a.team)
    expect(after).toMatchObject({ status: "active", configure_url: `https://github.com/organizations/acme/settings/installations/${NEW}` })
    expect(JSON.stringify(after)).not.toContain("/installations/99")
  })
})
