/**
 * The development Worker's GitHub App, `cmux-cloud-dev` under manaflow-ai (docs/cmux-next/cloud-dev-github-app.md).
 *
 *   bun backend/apps/api/scripts/dev-github-app.ts manifest   # print the App manifest (no secrets)
 *   bun backend/apps/api/scripts/dev-github-app.ts create     # one click: create the App from the manifest
 *
 * `create` serves a one-button page on 127.0.0.1:3011 that posts the manifest to GitHub's "new App" page for
 * the org. After the person clicks Create, GitHub redirects back here with a one-hour code; this script
 * exchanges it (POST /app-manifests/{code}/conversions, no token) and writes the App's slug, client id,
 * client secret, PKCS#8 private key and webhook secret to ~/.secrets/cmux-next-integrations-development.json
 * (mode 0600) for `wrangler secret bulk`. It prints names only, never a value, and changes no Worker.
 */
import { randomBytes, createPrivateKey } from "node:crypto"
import { mkdirSync, writeFileSync, existsSync } from "node:fs"
import { createServer } from "node:http"
import { homedir } from "node:os"
import { join } from "node:path"

export const ORG = "manaflow-ai"
export const APP_NAME = "cmux-cloud-dev"
/** wrangler.jsonc env.development INTEGRATIONS_CALLBACK_ORIGIN: the staging console finishes development connects. */
export const CALLBACK_ORIGIN = "https://console-staging.cmux.dev"
/** wrangler.jsonc env.development CLOUD_API_ORIGIN: GitHub webhooks go to its /v1/hooks/github. */
export const DEVELOPMENT_API_ORIGIN = "https://cmux-api-development.debussy.workers.dev"
export const LOCAL_PORT = 3011
export const SECRETS_FILE = join(homedir(), ".secrets", "cmux-next-integrations-development.json")

/**
 * What the code asks GitHub for, so the App must grant it (an installation token is never wider than the App):
 * - git credential and `cmux github gh` (cmux-host github_cli.rs): contents, pull_requests, issues write;
 *   checks, actions, statuses read; workflows write only when the team policy allows it (github-tokens.ts).
 * - Chief comments (providers.ts github.issue.comment): issues write.
 * - The org admin check at link time (providers.ts requireOrgAdmin): members read.
 * - metadata read: every App has it.
 * The staging App (cmux-cloud-staging) grants contents read and no checks, actions, statuses or workflows,
 * so a write token for `gh` or `git push` is refused there; development grants what the code asks.
 */
export const PERMISSIONS = {
  actions: "read",
  checks: "read",
  contents: "write",
  issues: "write",
  members: "read",
  metadata: "read",
  pull_requests: "write",
  statuses: "read",
  workflows: "write"
} as const

/** The staging App's events, plus what github-push.ts GITHUB_PUSH_EVENTS turns into live list updates. */
export const EVENTS = ["check_run", "check_suite", "issue_comment", "issues", "pull_request", "pull_request_review", "pull_request_review_thread", "push", "status"] as const

/** The App manifest (https://docs.github.com/apps/sharing-github-apps/registering-a-github-app-from-a-manifest). */
export const manifest = (redirectUrl = `http://127.0.0.1:${LOCAL_PORT}/created`) => ({
  name: APP_NAME,
  url: "https://cmux.com",
  description: "cmux Cloud development: repository access for development Cloud machines and agents, only where you allow.",
  hook_attributes: { url: `${DEVELOPMENT_API_ORIGIN}/v1/hooks/github`, active: true },
  // Where GitHub sends the manifest code after Create (this script), not where installs return.
  redirect_url: redirectUrl,
  // Installs and the OAuth authorize path both return to the console's callback page (api src/integrations/state.ts integrationCallbackUrl).
  callback_urls: [`${CALLBACK_ORIGIN}/integrations/callback`],
  // providers.ts github.complete needs the user's code beside installation_id: GitHub sends it only with this on.
  request_oauth_on_install: true,
  setup_on_update: true,
  public: true,
  default_permissions: PERMISSIONS,
  default_events: EVENTS
})

/** The Worker secrets the conversion answer fills (names as in api src/env.ts). The private key becomes PKCS#8. */
export const secretsFromConversion = (body: Record<string, unknown>): Record<string, string> => {
  const need = (k: string) => {
    const v = body[k]
    if (typeof v !== "string" || v.length === 0) throw new Error(`GitHub's conversion answer has no ${k}`)
    return v
  }
  const pkcs8 = createPrivateKey(need("pem")).export({ type: "pkcs8", format: "pem" }).toString()
  return {
    GITHUB_APP_SLUG: need("slug"),
    GITHUB_APP_CLIENT_ID: need("client_id"),
    GITHUB_APP_CLIENT_SECRET: need("client_secret"),
    GITHUB_APP_PRIVATE_KEY: pkcs8,
    ...(typeof body.webhook_secret === "string" && body.webhook_secret ? { GITHUB_WEBHOOK_SECRET: body.webhook_secret } : {})
  }
}

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

/** Whether a request's Host header names this script's own address, the only one the page and GitHub's redirect use. */
export const isLocalHost = (host: string | undefined): boolean => host === `127.0.0.1:${LOCAL_PORT}`

/** The one-button page: a form that posts the manifest to the org's new-App page. */
export const createPage = (state: string) => `<!doctype html><meta charset="utf-8"><title>Create ${APP_NAME}</title>
<form method="post" action="https://github.com/organizations/${ORG}/settings/apps/new?state=${encodeURIComponent(state)}">
<input type="hidden" name="manifest" value="${escapeHtml(JSON.stringify(manifest()))}">
<p>Creates the GitHub App <b>${APP_NAME}</b> under ${ORG} for the development Cloud backend.</p>
<button type="submit">Create ${APP_NAME} on GitHub</button></form>`

const create = () => {
  if (existsSync(SECRETS_FILE)) {
    console.error(`${SECRETS_FILE} already exists; move it aside before creating another App.`)
    process.exit(2)
  }
  const state = Array.from(randomBytes(16), (b) => b.toString(16).padStart(2, "0")).join("")
  const server = createServer(async (req, res) => {
    // Only this address: a page on another name that resolves here (DNS rebinding) must not read the state or post a code.
    if (!isLocalHost(req.headers.host)) {
      res.writeHead(421, { "content-type": "text/plain" })
      res.end(`Open http://127.0.0.1:${LOCAL_PORT}/ instead.`)
      return
    }
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${LOCAL_PORT}`)
    if (url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" })
      res.end(createPage(state))
      return
    }
    if (url.pathname !== "/created") {
      res.writeHead(404)
      res.end()
      return
    }
    const code = url.searchParams.get("code")
    if (url.searchParams.get("state") !== state || !code || !/^[A-Za-z0-9_-]{1,200}$/.test(code)) {
      res.writeHead(400)
      res.end("state mismatch or no code")
      return
    }
    try {
      const r = await fetch(`https://api.github.com/app-manifests/${code}/conversions`, {
        method: "POST",
        headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "cmux-dev-github-app" }
      })
      if (!r.ok) throw new Error(`GitHub conversion answered ${r.status}`)
      const secrets = secretsFromConversion((await r.json()) as Record<string, unknown>)
      mkdirSync(join(homedir(), ".secrets"), { recursive: true, mode: 0o700 })
      writeFileSync(SECRETS_FILE, `${JSON.stringify(secrets, null, 2)}\n`, { mode: 0o600, flag: "wx" })
      console.log(`Created ${secrets.GITHUB_APP_SLUG}. Wrote ${Object.keys(secrets).join(", ")} to ${SECRETS_FILE} (0600).`)
      res.writeHead(200, { "content-type": "text/plain" })
      res.end(`Created ${secrets.GITHUB_APP_SLUG}. Its credentials are in ${SECRETS_FILE}; you can close this tab.`)
    } catch (e) {
      console.error(`conversion failed: ${(e as Error).message}`)
      res.writeHead(502)
      res.end("conversion failed; see the terminal")
    }
    server.close()
  })
  server.listen(LOCAL_PORT, "127.0.0.1", () => console.log(`Open http://127.0.0.1:${LOCAL_PORT}/ and click Create.`))
}

if (import.meta.main) {
  const cmd = process.argv[2]
  if (cmd === "manifest") console.log(JSON.stringify(manifest(), null, 2))
  else if (cmd === "create") create()
  else {
    console.error("usage: dev-github-app.ts manifest|create")
    process.exit(2)
  }
}
