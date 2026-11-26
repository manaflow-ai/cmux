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

const status = async (bearer: string, team: string) => ((await (await worker.fetch(`https://api.test/v1/integrations/github/status?team=${team}`, { headers: { authorization: `Bearer ${bearer}` } })).json()) as any).connection
/** Ages every cached configure page in `team`'s ConnectionDO past its TTL, as time passing would. */
const ageConfigurePages = (team: string) =>
  inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (instance) => void instance.ctx.storage.sql.exec(`UPDATE github_configure_pages SET checked_at = 0`))

describe("a gone GitHub installation (cmux#55104)", { timeout: 60_000 }, () => {
  it("a gone installation names no settings page: uninstalled by webhook, or a 404 on a mint; Connect opens the install page (cmux#55104)", async () => {
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

  it("a deleted installation whose webhook never arrived names no settings page once the status read verifies it (cmux#55104)", async () => {
    const a = await signedInWithInstall("gh-gone-missed-webhook", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" } })
    expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: "https://github.com/settings/installations/99" })
    // Uninstalled on GitHub; no installation.deleted delivery reaches the API (a missed webhook, or the App changed).
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ message: "Not Found" }, 404)
    await ageConfigurePages(a.team)
    const after = await status(a.session, a.team)
    expect(after).toMatchObject({ status: "needs_reauth", configure_url: null })
    // Reconciled: the row is gone for good, so later reads ask GitHub nothing more and still name no page.
    const asked = gh.calls.filter((c) => c.url === "https://api.github.com/app/installations/99").length
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" } })
    await ageConfigurePages(a.team)
    expect(await status(a.session, a.team)).toMatchObject({ status: "needs_reauth", configure_url: null })
    expect(gh.calls.filter((c) => c.url === "https://api.github.com/app/installations/99").length).toBe(asked)
    // A mint refuses it as a relink, never a token for the deleted installation.
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("needs_reauth")
  })

  it("a suspended installation still names its settings page, where an owner lifts the suspension (cmux#55104)", async () => {
    const a = await signedInWithInstall("gh-gone-suspended", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "Organization" }, suspended_at: "2026-11-25T00:00:00Z" })
    expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: "https://github.com/organizations/acme/settings/installations/99" })
  })

  for (const how of ["reinstall-complete", "status-read"] as const) {
    it(`a reinstall is picked up: status names the new installation, never the deleted one (${how}, cmux#55104)`, async () => {
      const a = await signedInWithInstall(`gh-reinstall-${how}`, "cli")
      const { gh } = await linkGitHub(a.session, a.team)
      gh.routes["https://api.github.com/app/installations/99"] = () => ok({ id: 99, account: { login: "acme", type: "User" } })
      expect(await status(a.session, a.team)).toMatchObject({ status: "active", configure_url: "https://github.com/settings/installations/99" })
      // The person uninstalls the App (no webhook arrives) and installs it again: GitHub gives the account a new id.
      gh.routes["https://api.github.com/app/installations/99"] = () => ok({ message: "Not Found" }, 404)
      gh.routes["https://api.github.com/app/installations/100/access_tokens"] = () => ok({ token: "ghs_new", expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { contents: "read", metadata: "read" } }, 201)
      gh.routes["https://api.github.com/app/installations/100"] = () => ok({ id: 100, account: { login: "acme", type: "User" } })
      gh.routes["https://api.github.com/user/installations/100/repositories"] = () => ok({ repositories: [{ full_name: "acme/web" }] })
      // Routes match by prefix in insertion order: the installation list, then GET /user, go after the new repositories route.
      const user = gh.routes["https://api.github.com/user"]!
      delete gh.routes["https://api.github.com/user/installations"]
      delete gh.routes["https://api.github.com/user"]
      gh.routes["https://api.github.com/user/installations"] = () => ok({ installations: [{ id: 100, account: { login: "acme", type: "User" }, permissions: { contents: "write", metadata: "read" } }] })
      gh.routes["https://api.github.com/user"] = user
      const connect = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
      const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
      // "status-read": the old page is still cached when the reinstall lands, and the completion's own check is
      // unavailable, so only the status read's verification can reconcile it.
      if (how === "status-read") gh.routes["https://api.github.com/app/installations/99"] = () => new Response("unavailable", { status: 503 })
      const done = await op(a.session, "integration.complete", { state, code: "c", installation_id: "100", setup_action: "install" })
      expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })
      if (how === "status-read") {
        gh.routes["https://api.github.com/app/installations/99"] = () => ok({ message: "Not Found" }, 404)
        await ageConfigurePages(a.team)
      }
      for (let i = 0; i < 2; i++) {
        const now = await status(a.session, a.team)
        expect(now, how).toMatchObject({ id: done.body.value.id, status: "active", configure_url: "https://github.com/settings/installations/100" })
        expect(JSON.stringify(now)).not.toContain("/installations/99")
      }
      // The new installation mints; the deleted one is never asked for a token again.
      const minted = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })
      expect(minted.status, JSON.stringify(minted.body)).toBe(200)
      expect(gh.mints().at(-1)?.url).toBe("https://api.github.com/app/installations/100/access_tokens")
    })
  }
})
