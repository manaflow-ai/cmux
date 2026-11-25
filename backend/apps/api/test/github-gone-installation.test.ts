import { describe, expect, it } from "vitest"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { linkGitHub, ok, op, testEnv, token } from "./github-token-support.ts"

/**
 * cmux#55104: after the cmux GitHub App was uninstalled, GET /status kept naming the deleted installation's cached
 * settings page, the app's "Connect GitHub again" opened it, and GitHub answered 404: no way to reconnect.
 */
const hmacHex = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

describe("a gone GitHub installation (cmux#55104)", { timeout: 60_000 }, () => {
  it("a gone installation names no settings page: uninstalled by webhook, or a 404 on a mint; Connect opens the install page (cmux#55104)", async () => {
    const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
    const page = "https://github.com/settings/installations/99"
    const hook = async (event: string, payload: Record<string, unknown>) => {
      const body = JSON.stringify({ installation: { id: 99, account: { login: "acme" } }, ...payload })
      const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmacHex(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": event }, body })
      expect(res.status).toBe(200)
    }
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
      expect(after, how).toMatchObject({ status: "needs_reauth", configure_url: null })
      // Connect for one of the account's repositories opens the App's install page, not the deleted installation.
      gh.routes["https://api.github.com/users/acme/installation"] = () => ok({ message: "Not Found" }, 404)
      gh.routes["https://api.github.com/orgs/acme/installation"] = () => ok({ message: "Not Found" }, 404)
      const connect = await op(a.session, "integration.connect", { provider: "github", repo: "acme/web" })
      expect(connect.body.ok, JSON.stringify(connect.body)).toBe(true)
      expect(String(connect.body.value.authorize_url)).toMatch(/^https:\/\/github\.com\/apps\/[^/]+\/installations\/new/)
      expect(String(connect.body.value.authorize_url)).not.toContain("/settings/installations/")
    }
  })

})
