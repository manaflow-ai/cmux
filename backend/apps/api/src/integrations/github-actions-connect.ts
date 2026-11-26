import { createLocalJWKSet, jwtVerify, type JSONWebKeySet } from "jose"
import type { Env } from "../env.ts"
import { ProviderError, type Http } from "./provider-core.ts"

/**
 * A GitHub connection finished by a GitHub Actions workflow instead of a person's GitHub sign-in, for the automation
 * e2e on staging and development only (cmux-platform .github/workflows/automation-e2e.yml): Leo, "automations working
 * end to end (a GitHub "CI failed" event starts an AutoCloud agent that posts a fix PR)". The e2e's dogfood account
 * has no person who can click through GitHub, so the e2e signs the completion with the workflow's own OIDC token.
 *
 * What the OIDC token proves stands in for what the person's OAuth code proves (that someone with access to the
 * installation asked): GitHub signed it for a run of one allowed workflow file, on its repository's default branch,
 * which only people with write access to that repository can dispatch. The connection it makes covers that one
 * repository, in the installation on that repository's own owner, and nothing else. Never in production: the
 * Worker named cmux-api, or ENVIRONMENT production or anything not listed, refuses it as an invalid completion.
 */
export const ACTIONS_OIDC_ISSUER = "https://token.actions.githubusercontent.com"
const JWKS_URL = `${ACTIONS_OIDC_ISSUER}/.well-known/jwks`
const ENVIRONMENTS = new Set(["staging", "development", "local", "test"])
/** `job_workflow_ref` values whose runs may finish a connection: the workflow file at its repository's main branch. */
export const ACTIONS_CONNECT_WORKFLOWS: ReadonlySet<string> = new Set([
  "manaflow-ai/cmux-platform/.github/workflows/automation-e2e.yml@refs/heads/main"
])

/** The audience the workflow asks its OIDC token for: this deployment, so a staging token never finishes on development. */
export const actionsConnectAudience = (env: Pick<Env, "ENVIRONMENT">) => `cmux-api-${env.ENVIRONMENT}-github-connect`

export const actionsConnectAllowed = (env: Pick<Env, "ENVIRONMENT" | "WORKER_NAME">) =>
  ENVIRONMENTS.has(env.ENVIRONMENT) && env.WORKER_NAME !== "cmux-api"

export type ActionsRun = { readonly repository: string; readonly owner: string; readonly workflow: string; readonly run: string }

const refuse = (why: string): never => {
  throw new ProviderError("integration.state_invalid", `the GitHub Actions completion was refused: ${why}`)
}

/** Verifies the workflow's OIDC token (signature, issuer, audience, expiry, workflow, branch); the run it names. */
export const verifyActionsOidc = async (env: Pick<Env, "ENVIRONMENT" | "WORKER_NAME">, http: Http, token: string, now = Date.now()): Promise<ActionsRun> => {
  if (!actionsConnectAllowed(env)) refuse("this deployment does not take one")
  const res = await http(new Request(JWKS_URL, { headers: { accept: "application/json", "user-agent": "cmux-cloud" } })).catch(() => null)
  if (!res?.ok) throw new ProviderError("provider.error", "GitHub's Actions signing keys could not be read; retry", true, res?.status)
  const jwks = (await res.json().catch(() => null)) as JSONWebKeySet | null
  if (!jwks || !Array.isArray(jwks.keys)) throw new ProviderError("provider.error", "GitHub's Actions signing keys could not be read; retry", true)
  let claims: Record<string, unknown>
  try {
    const verified = await jwtVerify(token, createLocalJWKSet(jwks), {
      issuer: ACTIONS_OIDC_ISSUER,
      audience: actionsConnectAudience(env),
      algorithms: ["RS256"],
      currentDate: new Date(now),
      maxTokenAge: "10m"
    })
    claims = verified.payload as Record<string, unknown>
  } catch {
    return refuse("the OIDC token did not verify")
  }
  const workflow = String(claims.job_workflow_ref ?? "")
  const repository = String(claims.repository ?? "")
  const owner = String(claims.repository_owner ?? "")
  if (!ACTIONS_CONNECT_WORKFLOWS.has(workflow)) refuse("the workflow is not one that may connect GitHub")
  if (claims.ref !== "refs/heads/main" || claims.ref_type !== "branch") refuse("the run is not on main")
  if (!workflow.startsWith(`${repository}/`) || repository.split("/")[0] !== owner || owner === "") refuse("the token names another repository")
  return { repository, owner, workflow, run: String(claims.run_id ?? "") }
}
