import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { beforeEach, describe, expect, it } from "vitest"
import { github, type Http } from "../src/integrations/providers.ts"
import { forgetUserTokens, grantOf, resetUserTokensForTest, storeUserGrant, userAccessToken, userTokensSealable } from "../src/integrations/github-user-tokens.ts"

// Fix 7 of github-integration-audit.md: what a person starts posts as them (their GitHub App
// user-to-server token), only the refresh token is stored and sealed, and the App identity stays
// the fallback.

const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>

const fakeHttp = (routes: Record<string, (req: Request) => Promise<Response> | Response>) => {
  const calls: Array<{ url: string; auth: string | null; body: string }> = []
  const http: Http = async (req) => {
    const body = await req.clone().text()
    calls.push({ url: req.url, auth: req.headers.get("authorization"), body })
    const key = Object.keys(routes).find((k) => req.url.startsWith(k))
    if (!key) return new Response("not found", { status: 404 })
    return routes[key]!(req)
  }
  return { http, calls }
}
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const installToken = () => ok({ token: "ghs_inst", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201)
const commented = (id = 1) => ok({ id, html_url: `https://github.com/acme/web/issues/9#issuecomment-${id}` }, 201)
const params = { repo: "acme/web", issue: 9, body: "hi" }
const credential = { kind: "github_installation" as const, installation_id: 42 }

const sessionToken = async (stackUser: string) => {
  const key = await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(key)
}
const op = async (token: string, name: string, p: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params: p, idempotency_key: crypto.randomUUID(), origin: "cli" }) })
  return (await res.json()) as any
}

beforeEach(() => resetUserTokensForTest())

describe("GitHub user-to-server tokens", () => {
  it("reads a grant only when GitHub gave a refresh token", () => {
    expect(grantOf({ access_token: "ghu_a" }, 0)).toBeUndefined()
    expect(grantOf({ access_token: "ghu_a", refresh_token: "ghr_b", expires_in: 28800, refresh_token_expires_in: 15811200 }, 1000)).toEqual({
      access_token: "ghu_a", refresh_token: "ghr_b", expires_at: 1000 + 28800_000, refresh_expires_at: 1000 + 15811200_000
    })
    expect(userTokensSealable(testEnv as any)).toBe(true)
    expect(userTokensSealable({ ...testEnv, ENVIRONMENT: "production", INTEGRATIONS_KMS_KEY_ARN: undefined } as any)).toBe(false)
  })

  it("comments as the person when their token works, else as the App", async () => {
    const f = fakeHttp({
      "https://api.github.com/app/installations/42/access_tokens": installToken,
      "https://api.github.com/repos/acme/web/issues/9/comments": (req) => req.headers.get("authorization") === "Bearer ghu_ok" || req.headers.get("authorization") === "Bearer ghs_inst" ? commented() : ok({ message: "Not Found" }, 404)
    })
    const refused: Array<string> = []
    const asUser = (token: string | undefined) => ({ token: async () => token, refused: (t: string) => void refused.push(t) })

    await github.call(testEnv as any, f.http, credential, "github.issue.comment", params, undefined, asUser("ghu_ok"))
    expect(f.calls.map((c) => c.auth)).toEqual(["Bearer ghu_ok"])

    // A repository the person cannot reach: GitHub wrote nothing, the App posts.
    f.calls.length = 0
    await github.call(testEnv as any, f.http, credential, "github.issue.comment", params, undefined, asUser("ghu_norepo"))
    expect(f.calls.map((c) => c.auth)).toEqual(["Bearer ghu_norepo", expect.stringMatching(/^Bearer ey/), "Bearer ghs_inst"])
    expect(refused).toEqual([])

    // No token: the App, as before.
    f.calls.length = 0
    await github.call(testEnv as any, f.http, credential, "github.issue.comment", params, undefined, asUser(undefined))
    expect(f.calls.at(-1)!.auth).toBe("Bearer ghs_inst")
  })

  it("a revoked person token is dropped and the App posts; a 5xx is not retried as the App", async () => {
    const f = fakeHttp({
      "https://api.github.com/app/installations/42/access_tokens": installToken,
      "https://api.github.com/repos/acme/web/issues/9/comments": (req) =>
        req.headers.get("authorization") === "Bearer ghu_revoked" ? ok({ message: "Bad credentials" }, 401) : req.headers.get("authorization") === "Bearer ghu_502" ? ok({}, 502) : commented()
    })
    const refused: Array<string> = []
    await github.call(testEnv as any, f.http, credential, "github.issue.comment", params, undefined, { token: async () => "ghu_revoked", refused: (t) => void refused.push(t) })
    expect(refused).toEqual(["ghu_revoked"])
    expect(f.calls.at(-1)!.auth).toBe("Bearer ghs_inst")

    f.calls.length = 0
    await expect(github.call(testEnv as any, f.http, credential, "github.issue.comment", params, undefined, { token: async () => "ghu_502", refused: () => {} })).rejects.toMatchObject({ code: "mutation.indeterminate" })
    expect(f.calls).toHaveLength(1)
  })

  it("seals only the refresh token, refreshes and rotates it, and forgets it when GitHub refuses it", async () => {
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName("gh-user-token-unit"))
    await inDO(stub, async (_instance, state) => {
      const sql = state.storage.sql
      let refreshes = 0
      const f = fakeHttp({
        "https://github.com/login/oauth/access_token": async (req) => {
          const body = new URLSearchParams(await req.text())
          expect(body.get("grant_type")).toBe("refresh_token")
          refreshes++
          if (body.get("refresh_token") === "ghr_1") return ok({ access_token: "ghu_2", refresh_token: "ghr_2", expires_in: 28800, refresh_token_expires_in: 15811200 })
          return ok({ error: "bad_refresh_token" })
        }
      })
      const now = Date.now()
      expect(await storeUserGrant(sql, testEnv as any, f.http, "conn-a", "user-a", { access_token: "ghu_1", refresh_token: "ghr_1", expires_at: now + 3600_000, refresh_expires_at: now + 86400_000 }, now)).toBe(true)
      const row = sql.exec<{ sealed: string; generation: number }>(`SELECT sealed, generation FROM github_user_tokens WHERE connection = 'conn-a'`).one()
      expect(row.sealed).not.toContain("ghr_1")
      expect(row.sealed).not.toContain("ghu_1")
      expect(row.generation).toBe(1)

      // In memory while fresh: no refresh.
      expect(await userAccessToken(sql, testEnv as any, f.http, "conn-a", "user-a", now)).toBe("ghu_1")
      expect(refreshes).toBe(0)
      // Another person on the connection has none.
      expect(await userAccessToken(sql, testEnv as any, f.http, "conn-a", "user-b", now)).toBeUndefined()

      // A new isolate: refresh from the sealed row, two asks share one refresh, the token rotates.
      resetUserTokensForTest()
      const [a, b] = await Promise.all([1, 2].map(() => userAccessToken(sql, testEnv as any, f.http, "conn-a", "user-a", now)))
      expect([a, b]).toEqual(["ghu_2", "ghu_2"])
      expect(refreshes).toBe(1)
      expect(sql.exec<{ generation: number }>(`SELECT generation FROM github_user_tokens WHERE connection = 'conn-a'`).one().generation).toBe(2)

      // GitHub refuses the refresh token (the person revoked cmux): the row goes.
      resetUserTokensForTest()
      await storeUserGrant(sql, testEnv as any, f.http, "conn-a", "user-a", { access_token: "x", refresh_token: "ghr_spent", expires_at: now - 1, refresh_expires_at: now + 86400_000 }, now)
      resetUserTokensForTest()
      expect(await userAccessToken(sql, testEnv as any, f.http, "conn-a", "user-a", now)).toBeUndefined()
      expect(sql.exec(`SELECT 1 FROM github_user_tokens WHERE connection = 'conn-a'`).toArray()).toHaveLength(0)

      // Disconnect forgets every person's.
      await storeUserGrant(sql, testEnv as any, f.http, "conn-b", "user-a", { access_token: "ghu_b", refresh_token: "ghr_b", expires_at: now + 3600_000, refresh_expires_at: now + 86400_000 }, now)
      forgetUserTokens(sql, "conn-b")
      expect(await userAccessToken(sql, testEnv as any, f.http, "conn-b", "user-a", now)).toBeUndefined()
    })
  })

  it("end to end: linking with a refresh token makes that person's comments theirs; disconnect deletes the token", async () => {
    const token = await sessionToken("gh-user-e2e")
    const ensured = await op(token, "user.ensure", {})
    const team = ensured.value.personal_team as string
    const connect = await op(token, "integration.connect", { provider: "github", sharing: "team" })
    const conn = connect.value.connection.id as string
    const state = new URL(connect.value.authorize_url).searchParams.get("state")!
    const fake = fakeHttp({
      "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_person", refresh_token: "ghr_person", expires_in: 28800, refresh_token_expires_in: 15811200 }),
      "https://api.github.com/user/installations/77/repositories": () => ok({ repositories: [{ full_name: "acme/web" }] }),
      "https://api.github.com/user/installations": () => ok({ installations: [{ id: 77, account: { login: "acme", type: "Organization" }, permissions: { issues: "write" } }] }),
      "https://api.github.com/user": () => ok({ id: 5150, login: "person" }),
      "https://api.github.com/app/installations/77/access_tokens": installToken,
      "https://api.github.com/repos/acme/web/issues/9/comments": () => commented(3)
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "c", installation_id: "77", setup_action: "install" })
    expect(done).toMatchObject({ ok: true, value: { status: "active" } })

    expect(await op(token, "github.issue.comment", { connection: conn, ...params })).toMatchObject({ ok: true })
    expect(fake.calls.filter((c) => c.url.endsWith("/comments")).map((c) => c.auth)).toEqual(["Bearer ghu_person"])

    await inDO(connections, async (_instance, st) => {
      const rows = st.storage.sql.exec<{ sealed: string; github_id: number }>(`SELECT sealed, github_id FROM github_user_tokens WHERE connection = ?`, conn).toArray()
      expect(rows).toHaveLength(1)
      expect(rows[0]!.sealed).not.toContain("ghr_person")
      expect(rows[0]!.github_id).toBe(5150)
    })
    expect(await op(token, "integration.revoke", { connection: conn })).toMatchObject({ ok: true })
    await inDO(connections, async (_instance, st) => {
      expect(st.storage.sql.exec(`SELECT 1 FROM github_user_tokens WHERE connection = ?`, conn).toArray()).toHaveLength(0)
    })
  })
})
