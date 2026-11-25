import { importPKCS8, SignJWT } from "jose"
import type { IntegrationProvider } from "@cmux/protocol"
import type { Env } from "../env.ts"

/**
 * Provider clients behind the integration gateway. Each turns an approved
 * redirect into a non-secret account plus a credential, and runs provider ops
 * with that credential. All HTTP goes through `Http` so tests inject a fake.
 * Tokens are returned to the ConnectionDO only, which seals them.
 */

import { effectCall, failed, form, json, MAX_LINKED_REPOS, ProviderError, rateLimitMessage, rateLimitWait, type Credential, type Http, type ProviderImpl } from "./provider-core.ts"
import { grantOf } from "./github-user-tokens.ts"

import { gmail } from "./gmail.ts"
import { googleCalendar } from "./google-calendar.ts"

export { MAX_LINKED_REPOS, ProviderError, type Approved, type CallResult, type Credential, type Http, type LinkPolicy, type ProviderImpl } from "./provider-core.ts"

// ---------------------------------------------------------------- GitHub App

const GH_API = "https://api.github.com"
export const ghHeaders = (token: string) => ({
  authorization: `Bearer ${token}`,
  accept: "application/vnd.github+json",
  "x-github-api-version": "2022-11-28",
  "user-agent": "cmux-cloud"
})

/**
 * The App's own JWT (nine minutes), signed once and reused per isolate until a minute before it expires, for the
 * same App id and key: every mint, configure lookup and connect check used to import the key and sign anew.
 */
const appJwts = new Map<string, { jwt: string; expires_at: number; key: string }>()
export const appJwt = async (env: Env) => {
  const [issuer, pem] = [env.GITHUB_APP_CLIENT_ID!, env.GITHUB_APP_PRIVATE_KEY!]
  const cached = appJwts.get(issuer)
  if (cached && cached.key === pem && cached.expires_at - 60_000 > Date.now()) return cached.jwt
  const now = Math.floor(Date.now() / 1000)
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "RS256" }).setIssuer(issuer).setIssuedAt(now - 60).setExpirationTime(now + 540).sign(await importPKCS8(pem, "RS256"))
  // Only the signed string is shared, never a pending promise: Workers keep I/O per request context.
  appJwts.set(issuer, { jwt, expires_at: (now + 540) * 1000, key: pem })
  return jwt
}

/**
 * Quota headroom, for Axiom (`msg: github.ratelimit`): GitHub's `x-ratelimit-*` headers on an answer cmux-api got
 * with the App's JWT (`auth: app`) or an installation token (`auth: installation`, the installation's own budget).
 * At most one line per installation, auth and resource a minute, and every answer under a tenth of the limit.
 */
const headroomLogged = new Map<string, number>()
export const logGithubHeadroom = (res: Response, at: { readonly installation: number; readonly auth: "app" | "installation"; readonly op: string }) => {
  const [limit, remaining] = [Number(res.headers.get("x-ratelimit-limit")), Number(res.headers.get("x-ratelimit-remaining"))]
  if (!Number.isFinite(limit) || !Number.isFinite(remaining) || res.headers.get("x-ratelimit-limit") === null) return
  const resource = res.headers.get("x-ratelimit-resource") ?? "core"
  const key = `${at.installation}:${at.auth}:${resource}`
  const now = Date.now()
  const low = remaining < limit / 10
  if (!low && now - (headroomLogged.get(key) ?? 0) < 60_000) return
  headroomLogged.set(key, now)
  if (headroomLogged.size > 1000) headroomLogged.delete(headroomLogged.keys().next().value!)
  const reset = Number(res.headers.get("x-ratelimit-reset"))
  console.log(JSON.stringify({ msg: "github.ratelimit", installation: at.installation, auth: at.auth, op: at.op, resource, limit, remaining, used: Number(res.headers.get("x-ratelimit-used") ?? limit - remaining), reset_at: Number.isFinite(reset) ? new Date(reset * 1000).toISOString() : null, low, status: res.status }))
}

/** GitHub narrows an installation token to repository names inside the installation's account and exact permissions (it mints that or refuses). */
export type TokenNarrowing = { readonly repositories: ReadonlyArray<string>; readonly permissions: Readonly<Record<string, "read" | "write">> }

/** POST /app/installations/{id}/access_tokens with a narrowing body: the raw response, whose refusals github-tokens.ts maps. */
export const requestInstallationToken = async (env: Env, http: Http, installation: number, narrow: TokenNarrowing): Promise<Response> => {
  const res = await http(new Request(`${GH_API}/app/installations/${installation}/access_tokens`, { method: "POST", headers: { ...ghHeaders(await appJwt(env)), "content-type": "application/json" }, body: JSON.stringify(narrow) }))
  logGithubHeadroom(res, { installation, auth: "app", op: "mint" })
  return res
}

/** A 201's token (never logged), its expiry and the permissions GitHub granted. */
export const mintedToken = async (res: Response) => {
  const body = await json(res)
  const perms = (body.permissions && typeof body.permissions === "object" ? body.permissions : {}) as Record<string, unknown>
  return { token: String(body.token ?? ""), expires_at: Date.parse(String(body.expires_at ?? "")), permissions: Object.fromEntries(Object.entries(perms).filter((e): e is [string, string] => typeof e[1] === "string")) }
}

/** DELETE /installation/token with the token itself: true when GitHub revoked it or it is already dead. */
export const revokeInstallationToken = async (http: Http, token: string): Promise<boolean> => {
  const res = await http(new Request(`${GH_API}/installation/token`, { method: "DELETE", headers: ghHeaders(token) })).catch(() => null)
  return res !== null && (res.status === 204 || res.status === 401 || res.status === 404)
}

/**
 * Installation tokens for repository discovery live one hour; reuse until five minutes before expiry.
 * Per isolate, never stored. Tokens handed to callers are narrowed and kept per principal in the ledger (github-tokens.ts).
 */
const installationTokens = new Map<number, { token: string; expires_at: number }>()
/**
 * Mints in flight, per `http` (one per ConnectionDO, so a shared promise, and the refused Response it may carry,
 * never crosses a Workers I/O context) and installation: concurrent asks while none is cached share one mint.
 */
const inflightFor = <K>(table: WeakMap<Http, Map<K, Promise<string>>>, http: Http) => {
  let m = table.get(http)
  if (!m) table.set(http, (m = new Map()))
  return m
}
const installationMintsByHttp = new WeakMap<Http, Map<number, Promise<string>>>()
export const installationToken = async (env: Env, http: Http, installation: number) => {
  const cached = installationTokens.get(installation)
  if (cached && cached.expires_at - 5 * 60_000 > Date.now()) return cached.token
  const installationMints = inflightFor(installationMintsByHttp, http)
  const running = installationMints.get(installation)
  if (running) return running
  const mint = (async () => {
    const res = await http(new Request(`${GH_API}/app/installations/${installation}/access_tokens`, { method: "POST", headers: ghHeaders(await appJwt(env)) }))
    logGithubHeadroom(res, { installation, auth: "app", op: "discovery_mint" })
    if (!res.ok) throw new InstallationTokenRefused(res)
    const body = await json(res)
    const token = String(body.token ?? "")
    installationTokens.set(installation, { token, expires_at: Date.parse(String(body.expires_at ?? "")) || Date.now() + 50 * 60_000 })
    return token
  })().finally(() => installationMints.delete(installation))
  installationMints.set(installation, mint)
  return mint
}

/** GitHub refused an installation token: its response rides along, so a caller can read the refusal (github-tokens.ts). */
export class InstallationTokenRefused extends ProviderError {
  constructor(readonly response: Response) {
    const error = failed("github", response, "installation token")
    super(error.code, error.message, error.retryable, response.status)
  }
}

/** Drops a cached installation token GitHub refused (a 401), so the next ask mints a fresh one. */
export const forgetInstallationToken = (installation: number, token: string) => {
  if (installationTokens.get(installation)?.token === token) installationTokens.delete(installation)
}

/** Comment mutations use a separate cache: a repository-list token must never supply a write. */
const commentTokens = new Map<string, { token: string; expires_at: number }>()
const commentMintsByHttp = new WeakMap<Http, Map<string, Promise<string>>>()
const commentTokenKey = (installation: number, repo: string) => `${installation}:${repo.toLowerCase()}:issues:write`
const commentToken = async (env: Env, http: Http, installation: number, repo: string) => {
  const key = commentTokenKey(installation, repo)
  const cached = commentTokens.get(key)
  if (cached && cached.expires_at - 5 * 60_000 > Date.now()) return cached.token
  // Concurrent comments on one repository share one mint.
  const commentMints = inflightFor(commentMintsByHttp, http)
  const running = commentMints.get(key)
  if (running) return running
  const mint = (async () => {
    const res = await requestInstallationToken(env, http, installation, { repositories: [repo.split("/")[1]!], permissions: { issues: "write" } })
    if (!res.ok) throw failed("github", res, "installation token")
    const body = await json(res)
    const token = String(body.token ?? "")
    commentTokens.set(key, { token, expires_at: Date.parse(String(body.expires_at ?? "")) || Date.now() + 50 * 60_000 })
    return token
  })().finally(() => commentMints.delete(key))
  commentMints.set(key, mint)
  return mint
}

/** A GitHub App installation's `permissions` as a connection's scopes_granted (`contents:write`, sorted), at link time and on webhooks. */
export const githubScopesOf = (permissions: Readonly<Record<string, unknown>>): Array<string> =>
  Object.entries(permissions).filter((e): e is [string, string] => typeof e[1] === "string").map(([k, v]) => `${k}:${v}`).sort()

export const github: ProviderImpl = {
  configured: (env) => Boolean(env.GITHUB_APP_SLUG && env.GITHUB_APP_CLIENT_ID && env.GITHUB_APP_CLIENT_SECRET && env.GITHUB_APP_PRIVATE_KEY),
  defaultScopes: [],
  scopesFor: (op) => op === "github.issue.comment" ? ["issues:write"] : undefined,
  // App permissions are set on the App, not per request; the install page carries our state back.
  authorizeUrl: (env, state) => `https://github.com/apps/${env.GITHUB_APP_SLUG}/installations/new?state=${encodeURIComponent(state)}`,
  complete: async (env, http, p) => {
    const installation = Number(p.installation_id)
    // An organization member's install is a request until an owner approves it: GitHub comes back with
    // `setup_action=request` and no installation yet. Nothing to link; say what happens next.
    if (p.setup_action === "request" && !Number.isSafeInteger(installation)) {
      throw new ProviderError("integration.state_invalid", "GitHub sent your request to install the cmux GitHub App to the organization's owners. When an owner approves it, choose Connect GitHub in cmux again")
    }
    if (!p.code || !Number.isSafeInteger(installation)) {
      throw new ProviderError("integration.state_invalid", "GitHub returned no installation_id or code (enable 'Request user authorization during installation')")
    }
    // Prove the signed-in GitHub user can access this installation; an installation id alone is guessable.
    const tok = await http(
      new Request("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
        body: form({ client_id: env.GITHUB_APP_CLIENT_ID!, client_secret: env.GITHUB_APP_CLIENT_SECRET!, code: p.code })
      })
    )
    const t = await json(tok)
    // A rate-limited exchange is a wait, not an invalid link.
    const limited = tok.ok ? null : rateLimitWait(tok, Date.now())
    if (limited !== null) throw new ProviderError("provider.error", rateLimitMessage("github", limited), true, tok.status)
    if (!tok.ok || typeof t.access_token !== "string") throw new ProviderError("integration.state_invalid", "GitHub code exchange failed")
    const userToken = t.access_token
    const res = await http(new Request(`${GH_API}/user/installations?per_page=100`, { headers: ghHeaders(userToken) }))
    if (!res.ok) throw failed("github", res, "installation check")
    const list = ((await json(res)).installations ?? []) as Array<{ id: number; account?: { login?: string; type?: string; html_url?: string }; permissions?: Record<string, string> }>
    const inst = list.find((i) => i.id === installation)
    if (!inst) throw new ProviderError("integration.state_invalid", "this GitHub user cannot access that installation")
    const login = inst.account?.login ?? ""
    // The linking user's GitHub account (GET /user), read at most once per link.
    let me: Promise<{ ok: boolean; body: Record<string, unknown> }> | undefined
    const linkingUser = () =>
      (me ??= http(new Request(`${GH_API}/user`, { headers: ghHeaders(userToken) })).then(async (r) => ({ ok: r.ok, body: await json(r) })))

    if (p.policy.requireOrgAdmin) {
      if (inst.account?.type === "Organization") {
        // Needs the App's organization permission "Members: read".
        const m = await http(new Request(`${GH_API}/user/memberships/orgs/${encodeURIComponent(login)}`, { headers: ghHeaders(userToken) }))
        const mb = await json(m)
        if (!m.ok || mb.state !== "active" || mb.role !== "admin") throw new ProviderError("integration.state_invalid", `the team policy requires a ${login} organization admin to link GitHub`)
      } else {
        const { body: user } = await linkingUser()
        if (String(user.login ?? "").toLowerCase() !== login.toLowerCase()) throw new ProviderError("integration.state_invalid", "the team policy requires the account owner to link GitHub")
      }
    }

    // The repositories this user can reach through the installation bound what the connection may do.
    let repos: Array<string> | null = null
    if (p.policy.githubScope === "linking_user_repos") {
      repos = []
      for (let page = 1; page <= MAX_LINKED_REPOS / 100; page++) {
        const r = await http(new Request(`${GH_API}/user/installations/${installation}/repositories?per_page=100&page=${page}`, { headers: ghHeaders(userToken) }))
        if (!r.ok) throw failed("github", r, "repository list")
        const batch = ((await json(r)).repositories ?? []) as Array<{ full_name?: string }>
        for (const x of batch) if (typeof x.full_name === "string") repos.push(x.full_name)
        if (batch.length < 100) break
        // A full last page means more repositories than we record: refuse instead of silently truncating.
        if (page === MAX_LINKED_REPOS / 100) throw new ProviderError("integration.state_invalid", `this installation gives you more than ${MAX_LINKED_REPOS} repositories; ask a team admin to set the GitHub scope to the whole installation`)
      }
      repos.sort()
    }
    // Who linked, so a repository this same GitHub user later adds to the installation joins the recorded
    // list (connection-do.ts githubInstallationEvent). Unreadable: the connection records no id and an
    // added repository waits for a relink, as before.
    let linkedBy: number | undefined
    if (repos !== null) {
      const user = await linkingUser().catch(() => undefined)
      const id = user?.ok ? user.body.id : undefined
      if (typeof id === "number" && Number.isSafeInteger(id) && id > 0) linkedBy = id
    }
    return {
      account: { key: `github:installation:${installation}`, name: login || String(installation), ...(inst.account?.html_url ? { url: inst.account.html_url } : {}) },
      scopes_granted: githubScopesOf(inst.permissions ?? {}),
      credential: { kind: "github_installation", installation_id: installation },
      resources: { repos, ...(linkedBy !== undefined ? { linked_by_github_id: linkedBy } : {}) },
      // With expiring user tokens on, the exchange also gave a refresh token: effects this person starts
      // then run as them (fix 7 of github-integration-audit.md), not as the App bot.
      ...userGrant(t, linkedBy)
    }
  },
  call: async (env, http, credential, op, params, beforeEffect, asUser) => {
    if (credential.kind !== "github_installation") throw new ProviderError("provider.error", "wrong credential kind")
    if (op !== "github.issue.comment") throw new ProviderError("provider.error", `github cannot run ${op}`)
    const post = (token: string) => effectCall(
      http,
      "github",
      new Request(`${GH_API}/repos/${String(params.repo).split("/").map(encodeURIComponent).join("/")}/issues/${params.issue}/comments`, {
        method: "POST",
        headers: { ...ghHeaders(token), "content-type": "application/json" },
        body: JSON.stringify({ body: params.body })
      })
    )
    // As the person who asked, when they authorized cmux to act for them. GitHub refusing that token
    // (401 revoked, 403 not allowed, 404 no access to the repository) wrote nothing: post as the App.
    const userToken = await asUser?.token().catch(() => undefined)
    if (userToken) {
      await beforeEffect?.()
      const res = await post(userToken)
      if (res.ok) return commentReceipt(params, await json(res))
      if (!USER_TOKEN_FALLBACK.has(res.status)) throw failed("github", res, "comment", true)
      if (res.status === 401) asUser!.refused(userToken)
      await res.body?.cancel()
    }
    const token = await commentToken(env, http, credential.installation_id, String(params.repo))
    // Token acquisition can yield while membership, sharing, scopes or repository policy changes.
    await beforeEffect?.()
    const res = await post(token)
    if (!res.ok) {
      const error = failed("github", res, "comment", true)
      // Reconnect must not reuse a revoked token. A late 401 must not evict a newer token,
      // and the failed effect is still returned to the ledger, never retried here.
      const key = commentTokenKey(credential.installation_id, String(params.repo))
      if (error.code === "needs_reauth" && commentTokens.get(key)?.token === token) commentTokens.delete(key)
      throw error
    }
    return commentReceipt(params, await json(res))
  }
}

/** Statuses a person's token gets with nothing written, after which the App posts instead. */
const USER_TOKEN_FALLBACK = new Set([401, 403, 404])

const userGrant = (t: Record<string, unknown>, githubId: number | undefined) => {
  const grant = grantOf(t, Date.now())
  return grant ? { user_grant: { ...grant, ...(githubId !== undefined ? { github_id: githubId } : {}) } } : {}
}

const commentReceipt = (params: Record<string, unknown>, b: Record<string, unknown>) => {
  const returnedUrl = typeof b.html_url === "string" ? b.html_url.toLowerCase() : ""
  const issueUrl = `https://github.com/${params.repo}/issues/${params.issue}#issuecomment-${b.id}`.toLowerCase()
  const pullUrl = `https://github.com/${params.repo}/pull/${params.issue}#issuecomment-${b.id}`.toLowerCase()
  if (!Number.isSafeInteger(b.id) || Number(b.id) < 1 || !returnedUrl || returnedUrl !== issueUrl && returnedUrl !== pullUrl) {
    throw new ProviderError("mutation.indeterminate", "github returned no valid comment receipt; check the provider")
  }
  return { value: { id: b.id, url: b.html_url } }
}

// ---------------------------------------------------------------- Linear (OAuth, actor=app)

const LINEAR_TOKEN = "https://api.linear.app/oauth/token"
const linearTokenResponse = (b: Record<string, unknown>): Credential => ({
  kind: "oauth",
  access_token: String(b.access_token),
  ...(typeof b.refresh_token === "string" ? { refresh_token: b.refresh_token } : {}),
  ...(typeof b.expires_in === "number" ? { expires_at: Date.now() + b.expires_in * 1000 } : {})
})

const linearGraphql = async (http: Http, token: string, query: string, variables?: unknown, effect = false) => {
  const req = new Request("https://api.linear.app/graphql", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ query, ...(variables ? { variables } : {}) })
  })
  const res = effect ? await effectCall(http, "linear", req) : await http(req)
  if (!res.ok) throw failed("linear", res, "graphql", effect)
  const b = await json(res)
  if (Array.isArray(b.errors) && b.errors.length > 0) throw new ProviderError("provider.error", "linear graphql returned errors")
  return (b.data ?? {}) as Record<string, any>
}

export const linear: ProviderImpl = {
  configured: (env) => Boolean(env.LINEAR_CLIENT_ID && env.LINEAR_CLIENT_SECRET),
  defaultScopes: ["read", "write"],
  authorizeUrl: (env, state, scopes, redirectUri) =>
    `https://linear.app/oauth/authorize?${new URLSearchParams({ client_id: env.LINEAR_CLIENT_ID!, redirect_uri: redirectUri, response_type: "code", scope: scopes.join(","), state, actor: "app" })}`,
  complete: async (env, http, p) => {
    if (!p.code) throw new ProviderError("integration.state_invalid", "Linear returned no code")
    const res = await http(
      new Request(LINEAR_TOKEN, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({ code: p.code, redirect_uri: p.redirectUri, client_id: env.LINEAR_CLIENT_ID!, client_secret: env.LINEAR_CLIENT_SECRET!, grant_type: "authorization_code" })
      })
    )
    const b = await json(res)
    if (!res.ok || typeof b.access_token !== "string") throw new ProviderError("integration.state_invalid", "Linear code exchange failed")
    const credential = linearTokenResponse(b)
    const data = await linearGraphql(http, String(b.access_token), "{ viewer { organization { id name urlKey } } }")
    const org = data.viewer?.organization as { id?: string; name?: string; urlKey?: string } | undefined
    if (!org?.id) throw new ProviderError("provider.error", "Linear returned no organization")
    const scope = Array.isArray(b.scope) ? (b.scope as Array<string>) : String(b.scope ?? "").split(/[ ,]+/).filter(Boolean)
    return { account: { key: `linear:org:${org.id}`, name: org.name ?? org.id, ...(org.urlKey ? { url: `https://linear.app/${org.urlKey}` } : {}) }, scopes_granted: scope.sort(), credential }
  },
  refresh: async (env, http, credential) => {
    if (credential.kind !== "oauth" || credential.expires_at === undefined || credential.expires_at - 60_000 > Date.now()) return undefined
    if (!credential.refresh_token) throw new ProviderError("needs_reauth", "Linear token expired and has no refresh token")
    const res = await http(
      new Request(LINEAR_TOKEN, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({ refresh_token: credential.refresh_token, grant_type: "refresh_token", client_id: env.LINEAR_CLIENT_ID!, client_secret: env.LINEAR_CLIENT_SECRET! })
      })
    )
    const b = await json(res)
    if (!res.ok || typeof b.access_token !== "string") throw new ProviderError(res.status >= 500 || res.status === 429 ? "provider.error" : "needs_reauth", `Linear refresh failed: HTTP ${res.status}`, res.status >= 500 || res.status === 429)
    return linearTokenResponse(b)
  },
  call: async (_env, http, credential, op, params) => {
    if (credential.kind !== "oauth") throw new ProviderError("provider.error", "wrong credential kind")
    if (op === "linear.teams.list") {
      const data = await linearGraphql(http, credential.access_token, "{ teams(first: 100) { nodes { id key name } } }")
      return { value: { teams: ((data.teams?.nodes ?? []) as Array<{ id: string; key: string; name: string }>).map((t) => ({ id: t.id, key: t.key, name: t.name })) } }
    }
    if (op !== "linear.issue.create") throw new ProviderError("provider.error", `linear cannot run ${op}`)
    const data = await linearGraphql(
      http,
      credential.access_token,
      "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url title } } }",
      { input: { teamId: params.team_id, title: params.title, ...(params.description ? { description: params.description } : {}) } },
      true
    )
    const issue = data.issueCreate?.issue as { id?: string; identifier?: string; url?: string } | undefined
    if (!data.issueCreate?.success || !issue) throw new ProviderError("provider.error", "Linear issueCreate did not succeed")
    return { value: { id: issue.id, identifier: issue.identifier, url: issue.url } }
  }
}

// ---------------------------------------------------------------- Slack bot (OAuth v2)

export const slack: ProviderImpl = {
  configured: (env) => Boolean(env.SLACK_CLIENT_ID && env.SLACK_CLIENT_SECRET),
  defaultScopes: ["chat:write", "app_mentions:read", "channels:read"],
  authorizeUrl: (env, state, scopes, redirectUri) =>
    `https://slack.com/oauth/v2/authorize?${new URLSearchParams({ client_id: env.SLACK_CLIENT_ID!, scope: scopes.join(","), redirect_uri: redirectUri, state })}`,
  complete: async (env, http, p) => {
    if (!p.code) throw new ProviderError("integration.state_invalid", "Slack returned no code")
    const res = await http(
      new Request("https://slack.com/api/oauth.v2.access", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form({ client_id: env.SLACK_CLIENT_ID!, client_secret: env.SLACK_CLIENT_SECRET!, code: p.code, redirect_uri: p.redirectUri })
      })
    )
    const b = await json(res)
    const team = b.team as { id?: string; name?: string } | undefined
    if (!res.ok || b.ok !== true || typeof b.access_token !== "string" || !team?.id) throw new ProviderError("integration.state_invalid", "Slack code exchange failed")
    return {
      account: { key: `slack:team:${team.id}`, name: team.name ?? team.id, url: `https://app.slack.com/client/${team.id}` },
      scopes_granted: String(b.scope ?? "").split(",").filter(Boolean).sort(),
      credential: { kind: "oauth", access_token: b.access_token }
    }
  },
  call: async (_env, http, credential, op, params) => {
    if (credential.kind !== "oauth") throw new ProviderError("provider.error", "wrong credential kind")
    if (op !== "slack.post_as_bot") throw new ProviderError("provider.error", `slack cannot run ${op}`)
    const res = await effectCall(
      http,
      "slack",
      new Request("https://slack.com/api/chat.postMessage", {
        method: "POST",
        headers: { authorization: `Bearer ${credential.access_token}`, "content-type": "application/json; charset=utf-8" },
        body: JSON.stringify({ channel: params.channel, text: params.text })
      })
    )
    if (!res.ok) throw failed("slack", res, "chat.postMessage", true)
    const b = await json(res)
    if (b.ok !== true) {
      const err = String(b.error ?? "unknown")
      throw new ProviderError(err === "invalid_auth" || err === "token_revoked" || err === "account_inactive" ? "needs_reauth" : "provider.error", `slack chat.postMessage: ${err}`)
    }
    return { value: { channel: b.channel, ts: b.ts } }
  }
}

export const providers: Record<IntegrationProvider, ProviderImpl> = { github, linear, slack, gmail, google_calendar: googleCalendar }

/** Op families to providers: `mail.*` is Gmail and `calendar.*` Google Calendar until a second mail or calendar provider exists. */
const FAMILY: Readonly<Record<string, IntegrationProvider>> = { github: "github", linear: "linear", slack: "slack", mail: "gmail", calendar: "google_calendar" }
export const providerForOp = (op: string): IntegrationProvider | undefined => FAMILY[op.split(".")[0] ?? ""]

export const isProvider = (p: unknown): p is IntegrationProvider => typeof p === "string" && Object.hasOwn(providers, p)

/** The scopes a connect asks for: the caller's, or the provider's default for this deployment. */
export const scopesToRequest = (env: Env, impl: ProviderImpl, requested: ReadonlyArray<string>): ReadonlyArray<string> =>
  requested.length > 0 ? requested : typeof impl.defaultScopes === "function" ? impl.defaultScopes(env) : impl.defaultScopes
