import { env, exports } from "cloudflare:workers"
import { createLocalJWKSet, decodeJwt, errors as joseErrors, exportJWK, generateKeyPair, importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it, vi } from "vitest"
import { CI_SESSION_PATH, GITHUB_ACTIONS_ISSUER, handleCiSession, matchCiSessionToken, parseCiSessionTrust } from "../src/ci-session.ts"
import type { Env } from "../src/env.ts"
import type { StackServer } from "../src/stack-server.ts"

/**
 * ci-session.ts (hq#7076): a GitHub Actions job signs in as one test account by its OIDC token. Only a token
 * GitHub signed whose audience, repository, ref, workflow_ref and job_workflow_ref all equal a row's gets a
 * session, for that row's one Stack user, ending within the row's ttl.
 */

const worker = (exports as unknown as { default: Fetcher }).default
const testEnv = env as unknown as Env & { GITHUB_ACTIONS_TEST_PRIVATE_JWK: string }

const WORKFLOW = "manaflow-ai/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/main"
const ROW = {
  id: "ci-cloud-journey-prod",
  audience: "https://cloud-api.cmux.dev",
  repository: "manaflow-ai/cmux",
  repositoryId: "1144115288",
  ref: "refs/heads/main",
  workflowRef: WORKFLOW,
  events: ["schedule", "workflow_dispatch"],
  subject: "repo:manaflow-ai/cmux:ref:refs/heads/main",
  stackUser: "stack-user-journey",
  ttlSeconds: 2400
}
const CLAIMS = {
  repository: "manaflow-ai/cmux",
  repository_id: "1144115288",
  ref: "refs/heads/main",
  workflow_ref: WORKFLOW,
  job_workflow_ref: WORKFLOW,
  event_name: "schedule",
  run_id: "123",
  sub: "repo:manaflow-ai/cmux:ref:refs/heads/main"
}

const github = await generateKeyPair("RS256", { extractable: true })
const getKey = createLocalJWKSet({ keys: [{ ...(await exportJWK(github.publicKey)), kid: "gh1", alg: "RS256" }] })

const token = (claims: Record<string, unknown> = {}, opts: { iss?: string; aud?: string; key?: CryptoKey; iat?: number; exp?: number } = {}) =>
  new SignJWT({ jti: crypto.randomUUID(), ...CLAIMS, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "gh1" })
    .setIssuer(opts.iss ?? GITHUB_ACTIONS_ISSUER)
    .setAudience(opts.aud ?? ROW.audience)
    .setIssuedAt(opts.iat ?? Math.floor(Date.now() / 1000))
    .setExpirationTime(opts.exp ?? (opts.iat ?? Math.floor(Date.now() / 1000)) + 300)
    .sign(opts.key ?? github.privateKey)

const fakeJwt = (exp: number) => ["e30", Buffer.from(JSON.stringify({ exp })).toString("base64url"), "sig"].join(".")

const fakeStack = () => {
  const createSession = vi.fn(async (_user: string, _ms: number | undefined) => ({ access_token: fakeJwt(Math.floor(Date.now() / 1000) + 600), refresh_token: "refresh-never-returned" }))
  return { stack: { createSession } as unknown as StackServer, createSession }
}

const memoryClaims = () => {
  const seen = new Set<string>()
  return async (jti: string) => (seen.has(jti) ? false : (seen.add(jti), true))
}

const call = (bearer: string | undefined, trust: unknown = [ROW], stack = fakeStack().stack) =>
  handleCiSession(
    new Request(`https://cloud-api.cmux.dev${CI_SESSION_PATH}`, { method: "POST", headers: bearer ? { authorization: `Bearer ${bearer}` } : {} }),
    { ...testEnv, CI_SESSION_TRUST: JSON.stringify(trust) } as Env,
    { getKey, stack, claimOnce: memoryClaims() }
  )

describe("CI_SESSION_TRUST rows", () => {
  it("parses a row and refuses one that is loose, long-lived or inconsistent", () => {
    expect(parseCiSessionTrust(JSON.stringify([ROW])).rows).toHaveLength(1)
    expect(parseCiSessionTrust(undefined)).toEqual({ ok: true, rows: [] })
    for (const bad of [
      { ...ROW, ttlSeconds: 86_400 },
      { ...ROW, ttlSeconds: 0 },
      { ...ROW, ref: "refs/heads/*" },
      { ...ROW, workflowRef: "manaflow-ai/cmux/.github/workflows/cloud-journey-prod.yml" },
      // The workflow file must be in the row's repository and run from the row's ref.
      { ...ROW, workflowRef: "someone/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/main" },
      { ...ROW, workflowRef: "manaflow-ai/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/feat-cmux-next" },
      { ...ROW, audience: "http://cloud-api.cmux.dev" },
      { ...ROW, id: "cloud-journey" },
      { ...ROW, stackUser: "" },
      { ...ROW, extra: true },
      { ...ROW, repositoryId: undefined },
      { ...ROW, subject: undefined },
      { ...ROW, subject: "repo:someone/cmux:ref:refs/heads/main" },
      { ...ROW, events: [] },
      { ...ROW, events: ["pull_request_target"] },
      { ...ROW, events: ["schedule", "pull_request"] }
    ]) {
      expect(parseCiSessionTrust(JSON.stringify([bad])).ok, JSON.stringify(bad)).toBe(false)
    }
    expect(parseCiSessionTrust(JSON.stringify([ROW, ROW])).ok).toBe(false)
    expect(parseCiSessionTrust("{").ok).toBe(false)
  })
})

describe("matching a GitHub Actions token", () => {
  it("matches main's own cloud-journey-prod.yml run", async () => {
    const m = await matchCiSessionToken(await token(), [ROW], getKey)
    expect(m).toMatchObject({ ok: true, row: { id: ROW.id }, runId: "123" })
  })

  it("matches a token without job_workflow_ref (a job of the calling file itself)", async () => {
    expect(await matchCiSessionToken(await token({ job_workflow_ref: undefined }), [ROW], getKey)).toMatchObject({ ok: true })
  })

  it("refuses a token from another repository, ref or workflow", async () => {
    const other = "manaflow-ai/cmux/.github/workflows/other.yml@refs/heads/main"
    const branch = "manaflow-ai/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/feat-cmux-next"
    const fork = "someone/cmux/.github/workflows/cloud-journey-prod.yml@refs/heads/main"
    for (const claims of [
      { repository: "someone/cmux" },
      { repository_id: "1" },
      { repository: "someone/cmux", repository_id: "1", workflow_ref: fork, job_workflow_ref: fork },
      { ref: "refs/heads/feat-cmux-next" },
      { ref: "refs/heads/feat-cmux-next", workflow_ref: branch, job_workflow_ref: branch },
      { ref: "refs/pull/1/merge" },
      { workflow_ref: other, job_workflow_ref: other },
      // A job defined in another (reusable) workflow, called from the trusted file.
      { job_workflow_ref: "manaflow-ai/cmux/.github/workflows/reusable.yml@refs/heads/main" },
      { jti: undefined },
      // A pull_request_target run of the trusted file at main (it could run a fork's code), and other events.
      { event_name: "pull_request_target" },
      { event_name: "pull_request" },
      { event_name: "push" },
      { event_name: undefined },
      { repository_id: undefined },
      // Same repository, ref, workflow and event, but a different subject: a job run under an environment, or none.
      { sub: "repo:manaflow-ai/cmux:environment:cmux-next-cloud-journey" },
      { sub: "repo:manaflow-ai/cmux:ref:refs/heads/main:extra" },
      { sub: undefined }
    ]) {
      expect(await matchCiSessionToken(await token(claims), [ROW], getKey), JSON.stringify(claims)).toMatchObject({ ok: false })
    }
  })

  it("refuses a wrong audience, a foreign key, an old token and a non-GitHub issuer", async () => {
    expect(await matchCiSessionToken(await token({}, { aud: "https://vm.cmux.dev" }), [ROW], getKey)).toEqual({ ok: false, reason: "invalid" })
    // A list of audiences that includes the row's is still refused: GitHub mints one.
    const multi = await new SignJWT({ jti: crypto.randomUUID(), ...CLAIMS, aud: [ROW.audience, "https://other.example"] }).setProtectedHeader({ alg: "RS256", kid: "gh1" }).setIssuer(GITHUB_ACTIONS_ISSUER).setIssuedAt().setExpirationTime("5m").sign(github.privateKey)
    expect(await matchCiSessionToken(multi, [ROW], getKey)).toEqual({ ok: false, reason: "no-match" })
    const stranger = await generateKeyPair("RS256", { extractable: true })
    expect(await matchCiSessionToken(await token({}, { key: stranger.privateKey }), [ROW], getKey)).toEqual({ ok: false, reason: "invalid" })
    // Unexpired, but minted 20 minutes ago: past the 15-minute age cap.
    const now = Math.floor(Date.now() / 1000)
    expect(await matchCiSessionToken(await token({}, { iat: now - 20 * 60, exp: now + 300 }), [ROW], getKey)).toEqual({ ok: false, reason: "invalid" })
    expect(await matchCiSessionToken(await token({}, { iss: "https://example.com" }), [ROW], getKey)).toEqual({ ok: false, reason: "not-github" })
    expect(await matchCiSessionToken(await token(), [], getKey)).toEqual({ ok: false, reason: "no-trust" })
  })
})

describe(`POST ${CI_SESSION_PATH}`, () => {
  it("opens a session for the row's one user that ends within the run, and returns no refresh token", async () => {
    const { stack, createSession } = fakeStack()
    const r = await call(await token(), [ROW], stack)
    expect(r.status).toBe(200)
    const body = (await r.json()) as Record<string, string>
    expect(createSession).toHaveBeenCalledExactlyOnceWith(ROW.stackUser, ROW.ttlSeconds * 1000)
    expect(body.user).toBe(ROW.stackUser)
    expect(JSON.stringify(body)).not.toContain("refresh-never-returned")
    expect(decodeJwt(body.access_token!).exp).toBeGreaterThan(0)
    expect(Date.parse(body.session_expires_at!) - Date.now()).toBeLessThanOrEqual(ROW.ttlSeconds * 1000)
    expect(Date.parse(body.expires_at!)).toBeLessThanOrEqual(Date.parse(body.session_expires_at!))
  })

  it("refuses every mismatch with the same 401 and opens no session", async () => {
    const { stack, createSession } = fakeStack()
    for (const claims of [{ ref: "refs/heads/feat-cmux-next" }, { repository: "someone/cmux" }, { job_workflow_ref: "manaflow-ai/cmux/.github/workflows/x.yml@refs/heads/main" }]) {
      const r = await call(await token(claims), [ROW], stack)
      expect(r.status).toBe(401)
      expect(await r.json()).toEqual({ error: "this token is not trusted to sign in" })
    }
    expect((await call(undefined, [ROW], stack)).status).toBe(401)
    expect((await call(await token(), [{ ...ROW, ttlSeconds: 86_400 }], stack)).status).toBe(401)
    expect(createSession).not.toHaveBeenCalled()
  })

  it("refuses a replayed token, also through the Durable Object store", async () => {
    const { stack, createSession } = fakeStack()
    const once = memoryClaims()
    const t = await token()
    const req = () => new Request(`https://cloud-api.cmux.dev${CI_SESSION_PATH}`, { method: "POST", headers: { authorization: `Bearer ${t}` } })
    const e = { ...testEnv, CI_SESSION_TRUST: JSON.stringify([ROW]) } as Env
    expect((await handleCiSession(req(), e, { getKey, stack, claimOnce: once })).status).toBe(200)
    expect((await handleCiSession(req(), e, { getKey, stack, claimOnce: once })).status).toBe(401)
    expect(createSession).toHaveBeenCalledTimes(1)
    // The real store: the first claim of an id wins, a second is refused until it expires.
    const t2 = await token()
    expect((await handleCiSession(new Request(`https://x${CI_SESSION_PATH}`, { method: "POST", headers: { authorization: `Bearer ${t2}` } }), e, { getKey, stack })).status).toBe(200)
    expect((await handleCiSession(new Request(`https://x${CI_SESSION_PATH}`, { method: "POST", headers: { authorization: `Bearer ${t2}` } }), e, { getKey, stack })).status).toBe(401)
  })

  it("answers 503, not a refusal, when GitHub's keys cannot be read", async () => {
    const { stack, createSession } = fakeStack()
    // A timeout, and jose's generic error for a JWKS HTTP 4xx/5xx answer.
    for (const failure of [new joseErrors.JWKSTimeout(), new joseErrors.JOSEError("Expected 200 OK from the JSON Web Key Set HTTP response"), new TypeError("fetch failed")]) {
      const down = async () => {
        throw failure
      }
      const r = await handleCiSession(new Request(`https://x${CI_SESSION_PATH}`, { method: "POST", headers: { authorization: `Bearer ${await token()}` } }), { ...testEnv, CI_SESSION_TRUST: JSON.stringify([ROW]) } as Env, { getKey: down, stack, claimOnce: memoryClaims() })
      expect(r.status, String(failure)).toBe(503)
    }
    expect(createSession).not.toHaveBeenCalled()
  })

  it("is routed by the Worker and trusts no job without CI_SESSION_TRUST", async () => {
    const key = await importJWK(JSON.parse(testEnv.GITHUB_ACTIONS_TEST_PRIVATE_JWK) as JWK, "RS256")
    const signed = await new SignJWT(CLAIMS).setProtectedHeader({ alg: "RS256", kid: "github-actions-test" }).setIssuer(GITHUB_ACTIONS_ISSUER).setAudience(ROW.audience).setIssuedAt().setExpirationTime("5m").sign(key)
    const r = await worker.fetch(`https://api.test${CI_SESSION_PATH}`, { method: "POST", headers: { authorization: `Bearer ${signed}` } })
    expect(r.status).toBe(401)
  })
})
