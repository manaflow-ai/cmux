import { importPKCS8, SignJWT } from "jose"
import type { IntegrationProvider } from "@cmux/protocol"
import type { Env } from "../env.ts"

/**
 * Provider clients behind the integration gateway. Each turns an approved
 * redirect into a non-secret account plus a credential, and runs provider ops
 * with that credential. All HTTP goes through `Http` so tests inject a fake.
 * Tokens are returned to the ConnectionDO only, which seals them.
 */

export type Http = (request: Request) => Promise<Response>

export type Credential =
  | { readonly kind: "github_installation"; readonly installation_id: number }
  | { readonly kind: "oauth"; readonly access_token: string; readonly refresh_token?: string; readonly expires_at?: number }

export interface Approved {
  readonly account: { readonly key: string; readonly name: string; readonly url?: string }
  readonly scopes_granted: ReadonlyArray<string>
  readonly credential: Credential
}

export class ProviderError extends Error {
  constructor(
    readonly code: "provider.error" | "integration.unavailable" | "integration.state_invalid" | "needs_reauth",
    message: string,
    readonly retryable = false
  ) {
    super(message)
  }
}

export interface CallResult {
  readonly value: unknown
  /** A refreshed credential to seal in place of the old one. */
  readonly credential?: Credential
}

export interface ProviderImpl {
  readonly configured: (env: Env) => boolean
  readonly defaultScopes: ReadonlyArray<string>
  readonly authorizeUrl: (env: Env, state: string, scopes: ReadonlyArray<string>, redirectUri: string) => string
  readonly complete: (env: Env, http: Http, p: { code?: string; installation_id?: string; redirectUri: string }) => Promise<Approved>
  readonly call: (env: Env, http: Http, credential: Credential, op: string, params: Record<string, unknown>) => Promise<CallResult>
}

const json = async (res: Response): Promise<Record<string, unknown>> => {
  try {
    return (await res.json()) as Record<string, unknown>
  } catch {
    return {}
  }
}

/** Never echoes provider bodies (they can hold tokens or content); status and a short code only. */
const failed = (provider: string, res: Response, what: string) =>
  new ProviderError(res.status === 401 ? "needs_reauth" : "provider.error", `${provider} ${what} failed: HTTP ${res.status}`, res.status === 429 || res.status >= 500)

const form = (fields: Record<string, string>) => new URLSearchParams(fields).toString()

// ---------------------------------------------------------------- GitHub App

const GH_API = "https://api.github.com"
const ghHeaders = (token: string) => ({
  authorization: `Bearer ${token}`,
  accept: "application/vnd.github+json",
  "x-github-api-version": "2022-11-28",
  "user-agent": "cmux-cloud"
})

const appJwt = async (env: Env) => {
  const key = await importPKCS8(env.GITHUB_APP_PRIVATE_KEY!, "RS256")
  const now = Math.floor(Date.now() / 1000)
  return new SignJWT({}).setProtectedHeader({ alg: "RS256" }).setIssuer(env.GITHUB_APP_CLIENT_ID!).setIssuedAt(now - 60).setExpirationTime(now + 540).sign(key)
}

/** Installation tokens live one hour; reuse until five minutes before expiry. Per isolate, never stored. */
const installationTokens = new Map<number, { token: string; expires_at: number }>()
const installationToken = async (env: Env, http: Http, installation: number) => {
  const cached = installationTokens.get(installation)
  if (cached && cached.expires_at - 5 * 60_000 > Date.now()) return cached.token
  const res = await http(new Request(`${GH_API}/app/installations/${installation}/access_tokens`, { method: "POST", headers: ghHeaders(await appJwt(env)) }))
  if (!res.ok) throw failed("github", res, "installation token")
  const body = await json(res)
  const token = String(body.token ?? "")
  installationTokens.set(installation, { token, expires_at: Date.parse(String(body.expires_at ?? "")) || Date.now() + 50 * 60_000 })
  return token
}

export const github: ProviderImpl = {
  configured: (env) => Boolean(env.GITHUB_APP_SLUG && env.GITHUB_APP_CLIENT_ID && env.GITHUB_APP_CLIENT_SECRET && env.GITHUB_APP_PRIVATE_KEY),
  defaultScopes: [],
  // App permissions are set on the App, not per request; the install page carries our state back.
  authorizeUrl: (env, state) => `https://github.com/apps/${env.GITHUB_APP_SLUG}/installations/new?state=${encodeURIComponent(state)}`,
  complete: async (env, http, p) => {
    const installation = Number(p.installation_id)
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
    if (!tok.ok || typeof t.access_token !== "string") throw new ProviderError("integration.state_invalid", "GitHub code exchange failed")
    const res = await http(new Request(`${GH_API}/user/installations?per_page=100`, { headers: ghHeaders(t.access_token) }))
    if (!res.ok) throw failed("github", res, "installation check")
    const list = ((await json(res)).installations ?? []) as Array<{ id: number; account?: { login?: string; html_url?: string }; permissions?: Record<string, string> }>
    const inst = list.find((i) => i.id === installation)
    if (!inst) throw new ProviderError("integration.state_invalid", "this GitHub user cannot access that installation")
    return {
      account: { key: `github:installation:${installation}`, name: inst.account?.login ?? String(installation), ...(inst.account?.html_url ? { url: inst.account.html_url } : {}) },
      scopes_granted: Object.entries(inst.permissions ?? {}).map(([k, v]) => `${k}:${v}`).sort(),
      credential: { kind: "github_installation", installation_id: installation }
    }
  },
  call: async (env, http, credential, op, params) => {
    if (credential.kind !== "github_installation") throw new ProviderError("provider.error", "wrong credential kind")
    if (op !== "github.issue.comment") throw new ProviderError("provider.error", `github cannot run ${op}`)
    const token = await installationToken(env, http, credential.installation_id)
    const res = await http(
      new Request(`${GH_API}/repos/${params.repo}/issues/${params.issue}/comments`, {
        method: "POST",
        headers: { ...ghHeaders(token), "content-type": "application/json" },
        body: JSON.stringify({ body: params.body })
      })
    )
    if (!res.ok) throw failed("github", res, "comment")
    const b = await json(res)
    return { value: { id: b.id, url: b.html_url } }
  }
}

// ---------------------------------------------------------------- Linear (OAuth, actor=app)

const LINEAR_TOKEN = "https://api.linear.app/oauth/token"
const linearTokenResponse = (b: Record<string, unknown>): Credential => ({
  kind: "oauth",
  access_token: String(b.access_token),
  ...(typeof b.refresh_token === "string" ? { refresh_token: b.refresh_token } : {}),
  ...(typeof b.expires_in === "number" ? { expires_at: Date.now() + b.expires_in * 1000 } : {})
})

const linearGraphql = async (http: Http, token: string, query: string, variables?: unknown) => {
  const res = await http(
    new Request("https://api.linear.app/graphql", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ query, ...(variables ? { variables } : {}) })
    })
  )
  if (!res.ok) throw failed("linear", res, "graphql")
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
  call: async (env, http, credential, op, params) => {
    if (credential.kind !== "oauth") throw new ProviderError("provider.error", "wrong credential kind")
    if (op !== "linear.issue.create") throw new ProviderError("provider.error", `linear cannot run ${op}`)
    let cred = credential
    let refreshed: Credential | undefined
    if (cred.expires_at !== undefined && cred.expires_at - 60_000 < Date.now()) {
      if (!cred.refresh_token) throw new ProviderError("needs_reauth", "Linear token expired and has no refresh token")
      const res = await http(
        new Request(LINEAR_TOKEN, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: form({ refresh_token: cred.refresh_token, grant_type: "refresh_token", client_id: env.LINEAR_CLIENT_ID!, client_secret: env.LINEAR_CLIENT_SECRET! })
        })
      )
      const b = await json(res)
      if (!res.ok || typeof b.access_token !== "string") throw new ProviderError("needs_reauth", `Linear refresh failed: HTTP ${res.status}`)
      cred = linearTokenResponse(b) as typeof cred
      refreshed = cred
    }
    const data = await linearGraphql(
      http,
      cred.access_token,
      "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url title } } }",
      { input: { teamId: params.team_id, title: params.title, ...(params.description ? { description: params.description } : {}) } }
    )
    const issue = data.issueCreate?.issue as { id?: string; identifier?: string; url?: string } | undefined
    if (!data.issueCreate?.success || !issue) throw new ProviderError("provider.error", "Linear issueCreate did not succeed")
    return { value: { id: issue.id, identifier: issue.identifier, url: issue.url }, ...(refreshed ? { credential: refreshed } : {}) }
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
    const res = await http(
      new Request("https://slack.com/api/chat.postMessage", {
        method: "POST",
        headers: { authorization: `Bearer ${credential.access_token}`, "content-type": "application/json; charset=utf-8" },
        body: JSON.stringify({ channel: params.channel, text: params.text })
      })
    )
    if (!res.ok) throw failed("slack", res, "chat.postMessage")
    const b = await json(res)
    if (b.ok !== true) {
      const err = String(b.error ?? "unknown")
      throw new ProviderError(err === "invalid_auth" || err === "token_revoked" || err === "account_inactive" ? "needs_reauth" : "provider.error", `slack chat.postMessage: ${err}`)
    }
    return { value: { channel: b.channel, ts: b.ts } }
  }
}

export const providers: Record<IntegrationProvider, ProviderImpl> = { github, linear, slack }

export const providerForOp = (op: string): IntegrationProvider | undefined => {
  const p = op.split(".")[0]
  return p === "github" || p === "linear" || p === "slack" ? p : undefined
}
