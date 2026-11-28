/**
 * Shared types and helpers of the provider clients (providers.ts, google.ts,
 * gmail.ts, google-calendar.ts). No provider imports another provider.
 */

import type { Env } from "../env.ts"
import type { GithubUserGrant } from "./github-user-tokens.ts"

export type Http = (request: Request) => Promise<Response>

export type Credential =
  | { readonly kind: "github_installation"; readonly installation_id: number }
  | { readonly kind: "oauth"; readonly access_token: string; readonly refresh_token?: string; readonly expires_at?: number }

export interface Approved {
  readonly account: { readonly key: string; readonly name: string; readonly url?: string }
  readonly scopes_granted: ReadonlyArray<string>
  readonly credential: Credential
  readonly resources?: { readonly repos: ReadonlyArray<string> | null; readonly linked_by_github_id?: number }
  /**
   * GitHub: the linking person's user-to-server grant, when GitHub issued a refresh token (the App's
   * "expire user authorization tokens"). The ConnectionDO seals only its refresh token (github-user-tokens.ts).
   */
  readonly user_grant?: GithubUserGrant
}

/**
 * The calling person's own provider token, when they authorized one (GitHub: github-user-tokens.ts).
 * `refused` drops a token the provider answered 401 for, so the next ask refreshes it.
 */
export interface ActAsUser {
  readonly token: () => Promise<string | undefined>
  readonly refused: (token: string) => void
}

/** The parts of the team integration policy a provider needs while linking. */
export interface LinkPolicy {
  readonly githubScope: "linking_user_repos" | "installation"
  readonly requireOrgAdmin: boolean
}

/** Repositories recorded per GitHub connection; a larger installation links with installation scope only. */
export const MAX_LINKED_REPOS = 1000

export class ProviderError extends Error {
  constructor(
    readonly code: "provider.error" | "integration.unavailable" | "integration.state_invalid" | "needs_reauth" | "mutation.indeterminate" | "policy.denied",
    message: string,
    readonly retryable = false,
    /** The provider's HTTP status when one caused this error. */
    readonly status?: number
  ) {
    super(message)
  }
}

export interface CallResult {
  readonly value: unknown
}

export interface ProviderImpl {
  readonly configured: (env: Env) => boolean
  /** Scopes asked for when `integration.connect` names none (may depend on the deployment). */
  readonly defaultScopes: ReadonlyArray<string> | ((env: Env) => ReadonlyArray<string>)
  /**
   * A refusal message when this deployment may not ask for these scopes (for
   * example restricted Gmail scopes before the CASA validation), else undefined.
   */
  readonly refuseScopes?: (env: Env, scopes: ReadonlyArray<string>) => string | undefined
  /** `connection` lets a provider derive a per-attempt PKCE verifier on the server (never in the URL). */
  readonly authorizeUrl: (env: Env, state: string, scopes: ReadonlyArray<string>, redirectUri: string, connection: string) => string | Promise<string>
  readonly complete: (env: Env, http: Http, p: { code?: string; installation_id?: string; setup_action?: string; actions_oidc?: string; redirectUri: string; policy: LinkPolicy; connection: string; state: string; scopes_requested: ReadonlyArray<string> }) => Promise<Approved>
  /**
   * Scopes an op needs (any one of them suffices), checked against the
   * connection's granted scopes before the call; undefined = no check. With
   * granular consent a user may grant fewer scopes than were asked for.
   */
  readonly scopesFor?: (op: string) => ReadonlyArray<string> | undefined
  readonly call: (env: Env, http: Http, credential: Credential, op: string, params: Record<string, unknown>, beforeEffect?: () => Promise<void>, asUser?: ActAsUser) => Promise<CallResult>
  /**
   * A fresh credential when this one is (about to be) expired, else undefined.
   * The ConnectionDO seals the result before any provider call uses it and runs
   * one refresh at a time per connection (rotating refresh tokens are single use).
   */
  readonly refresh?: (env: Env, http: Http, credential: Credential) => Promise<Credential | undefined>
  /**
   * Revokes the grant at the provider after a disconnect: `done` when the
   * provider confirmed or the grant was already gone, `retry` otherwise.
   */
  readonly revoke?: (env: Env, http: Http, credential: Credential) => Promise<"done" | "retry">
  /**
   * Account keys that share one provider grant with this one (Google: the
   * Gmail and Calendar connections of one Google user share the grant of our
   * OAuth client). A revoke is skipped while any of them is still linked.
   */
  readonly grantKeys?: (accountKey: string) => ReadonlyArray<string>
}

export const json = async (res: Response): Promise<Record<string, unknown>> => {
  try {
    return (await res.json()) as Record<string, unknown>
  } catch {
    return {}
  }
}

/** Seconds a provider asks us to wait (Retry-After, else the primary limit's reset), at least 1; 60 when it names none. */
export const retryAfterSeconds = (res: Response, now: number): number => {
  const [after, reset] = [Number(res.headers.get("retry-after")), Number(res.headers.get("x-ratelimit-reset"))]
  return Number.isFinite(after) && after > 0 ? Math.ceil(after) : Number.isFinite(reset) && reset * 1000 > now ? Math.max(1, Math.ceil(reset - now / 1000)) : 60
}

/**
 * GitHub's rate limits, read from one answer: a 429; a 403 whose headers say the primary limit is spent
 * (`x-ratelimit-remaining: 0`) or that name a wait (`retry-after`, a secondary limit); or, when the caller read the
 * body, a 403 whose message names a secondary rate limit or abuse detection (GitHub sends some without headers).
 * The wait in seconds, else null.
 */
export const rateLimitWait = (res: Response, now: number, message = ""): number | null =>
  res.status === 429 || (res.status === 403 && (res.headers.get("x-ratelimit-remaining") === "0" || res.headers.has("retry-after") || /rate limit|abuse detection/i.test(message)))
    ? retryAfterSeconds(res, now)
    : null

/** What a caller reads for a rate limit: the wait, never "connect again". */
export const rateLimitMessage = (provider: string, seconds: number) =>
  `${provider === "github" ? "GitHub" : provider} is rate limiting cmux; try again in ${seconds} s`

/**
 * Never echoes provider bodies (they can hold tokens or content); status and a
 * short code only. For the call that makes the effect (`effect`), a 5xx may
 * come after the provider acted, so it is indeterminate, not retryable; only a
 * 429 (refused before acting) releases the key for a retry.
 */
export const failed = (provider: string, res: Response, what: string, effect = false) => {
  if (res.status === 401) return new ProviderError("needs_reauth", `${provider} ${what} failed: HTTP 401`)
  // A rate limit (a 429, or a 403 with an exhausted limit or a wait) was refused before acting: retryable, and it
  // says nothing about the connection, so it names the wait and never asks for a reconnect.
  const limited = rateLimitWait(res, Date.now())
  if (limited !== null) return new ProviderError("provider.error", rateLimitMessage(provider, limited), true, res.status)
  if (effect && res.status >= 500) return new ProviderError("mutation.indeterminate", `${provider} ${what}: HTTP ${res.status}; the provider may have acted`)
  return new ProviderError("provider.error", `${provider} ${what} failed: HTTP ${res.status}`, res.status === 429 || (!effect && res.status >= 500))
}

/** The effect request: a network failure after sending is indeterminate too. */
export const effectCall = async (http: Http, provider: string, req: Request): Promise<Response> => {
  try {
    return await http(req)
  } catch {
    throw new ProviderError("mutation.indeterminate", `${provider}: the request failed in flight; the provider may have acted`)
  }
}

export const form = (fields: Record<string, string>) => new URLSearchParams(fields).toString()

