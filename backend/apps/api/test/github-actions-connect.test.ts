import { exportJWK, generateKeyPair, SignJWT } from "jose"
import { describe, expect, it } from "vitest"
import { ACTIONS_OIDC_ISSUER } from "../src/integrations/github-actions-connect.ts"
import { ProviderError } from "../src/integrations/provider-core.ts"
import { github } from "../src/integrations/providers.ts"
import { testEnv } from "./github-token-support.ts"

/**
 * The automation e2e's GitHub connection without a person (github-actions-connect.ts): a GitHub Actions OIDC token
 * of the one allowed workflow on main finishes a GitHub completion on staging, for that repository only; production
 * and any other workflow, branch, audience or owner are refused.
 */
const WORKFLOW = "manaflow-ai/cmux-platform/.github/workflows/automation-e2e.yml@refs/heads/main"
const keys = await generateKeyPair("RS256", { extractable: true })
const jwk = { ...(await exportJWK(keys.publicKey)), kid: "k1", alg: "RS256", use: "sig" }
const staging = { ...testEnv, ENVIRONMENT: "staging", WORKER_NAME: "cmux-api-staging" } as any

const oidc = (claims: Record<string, unknown> = {}, audience = "cmux-api-staging-github-connect") =>
  new SignJWT({ repository: "manaflow-ai/cmux-platform", repository_owner: "manaflow-ai", job_workflow_ref: WORKFLOW, ref: "refs/heads/main", ref_type: "branch", run_id: "1", ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "k1" })
    .setIssuer(ACTIONS_OIDC_ISSUER)
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(keys.privateKey)

const http = (login = "manaflow-ai") => async (req: Request) => {
  if (req.url === `${ACTIONS_OIDC_ISSUER}/.well-known/jwks`) return Response.json({ keys: [jwk] })
  if (req.url === "https://api.github.com/app/installations/77") return Response.json({ id: 77, account: { login, html_url: `https://github.com/${login}` }, permissions: { contents: "write", pull_requests: "write" } })
  return new Response("not found", { status: 404 })
}
const ask = (actions_oidc: string, policy: { githubScope: "linking_user_repos" | "installation"; requireOrgAdmin: boolean } = { githubScope: "linking_user_repos", requireOrgAdmin: false }) => ({
  actions_oidc, installation_id: "77", redirectUri: "https://api.test/cb", policy, connection: "conn_x", state: "s", scopes_requested: []
})
const refusal = (p: Promise<unknown>) => p.then(() => "accepted", (e: unknown) => (e instanceof ProviderError ? e.message : String(e)))

describe("GitHub connect from the automation e2e's Actions run", () => {
  it("staging: the allowed workflow on main links its owner's installation, for its own repository only", async () => {
    const approved = await github.complete(staging, http(), ask(await oidc()))
    expect(approved).toEqual({
      account: { key: "github:installation:77", name: "manaflow-ai", url: "https://github.com/manaflow-ai" },
      scopes_granted: ["contents:write", "pull_requests:write"],
      credential: { kind: "github_installation", installation_id: 77 },
      resources: { repos: ["manaflow-ai/cmux-platform"] }
    })
  })

  it("refuses production, other workflows, branches, audiences, owners and the installation scope", async () => {
    const production = { ...testEnv, ENVIRONMENT: "production", WORKER_NAME: "cmux-api" } as any
    expect(await refusal(github.complete(production, http(), ask(await oidc())))).toMatch(/does not take one/)
    expect(await refusal(github.complete({ ...staging, WORKER_NAME: "cmux-api" }, http(), ask(await oidc())))).toMatch(/does not take one/)
    expect(await refusal(github.complete(staging, http(), ask(await oidc({ job_workflow_ref: "manaflow-ai/cmux-platform/.github/workflows/other.yml@refs/heads/main" }))))).toMatch(/not one that may/)
    expect(await refusal(github.complete(staging, http(), ask(await oidc({ ref: "refs/heads/lane/x" }))))).toMatch(/not on main/)
    expect(await refusal(github.complete(staging, http(), ask(await oidc({}, "cmux-api-development-github-connect"))))).toMatch(/did not verify/)
    expect(await refusal(github.complete(staging, http(), ask(await oidc({ repository: "evil/cmux-platform" }))))).toMatch(/another repository/)
    expect(await refusal(github.complete(staging, http("someone-else"), ask(await oidc())))).toMatch(/not on the run's repository owner/)
    expect(await refusal(github.complete(staging, http(), ask(await oidc(), { githubScope: "installation", requireOrgAdmin: false })))).toMatch(/needs a person/)
    const forged = (await oidc()).split(".")
    forged[1] = Buffer.from(JSON.stringify({ iss: ACTIONS_OIDC_ISSUER, aud: "cmux-api-staging-github-connect", job_workflow_ref: WORKFLOW })).toString("base64url")
    expect(await refusal(github.complete(staging, http(), ask(forged.join("."))))).toMatch(/did not verify/)
  })
})
