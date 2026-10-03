import { env, exports } from "cloudflare:workers"
import { evictDurableObject, runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { aadFor, open, seal } from "../src/integrations/crypto.ts"
import { github, linear, slack, type Http } from "../src/integrations/providers.ts"

const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>

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
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  const text = await res.text()
  try {
    return { status: res.status, json: JSON.parse(text) as any }
  } catch {
    throw new Error(`${path} ${JSON.stringify(body).slice(0, 200)} -> ${res.status} non-JSON: ${text.slice(0, 200)}`)
  }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const signedIn = async (stackUser: string) => {
  const token = await sessionToken(stackUser)
  const e = await op(token, "user.ensure", {})
  return { token, team: e.json.value.personal_team as string, user: e.json.value.id as string }
}
const hmac = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

/** A scripted provider: each route answers once per call and records requests. */
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

describe("credential envelope", () => {
  it("round-trips and refuses another AAD or KEK", async () => {
    const kek = testEnv.INTEGRATIONS_KEK as string
    const aad = aadFor("conn_a", "team_a", "slack", 1)
    const sealed = await seal(kek, "xoxb-secret", aad)
    expect(JSON.stringify(sealed)).not.toContain("xoxb")
    expect(await open(kek, sealed, aad)).toBe("xoxb-secret")
    await expect(open(kek, sealed, aadFor("conn_a", "team_b", "slack", 1))).rejects.toThrow()
    await expect(open(kek, sealed, aadFor("conn_a", "team_a", "slack", 2))).rejects.toThrow()
    const other = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
    await expect(open(other, sealed, aad)).rejects.toThrow()
  })
})

describe("provider clients (fake HTTP)", () => {
  const e = testEnv as any
  const userScope = { githubScope: "linking_user_repos" as const, requireOrgAdmin: false }
  const ghLink = (opts: { installations?: unknown; role?: string; repos?: Array<string> } = {}) =>
    fakeHttp({
      "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
      "https://api.github.com/user/installations/42/repositories": () => ok({ repositories: (opts.repos ?? ["manaflow-ai/cmux"]).map((full_name) => ({ full_name })) }),
      "https://api.github.com/user/installations": () =>
        ok(opts.installations ?? { installations: [{ id: 42, account: { login: "manaflow-ai", type: "Organization", html_url: "https://github.com/manaflow-ai" }, permissions: { issues: "write" } }] }),
      "https://api.github.com/user/memberships/orgs/manaflow-ai": () => ok({ state: "active", role: opts.role ?? "member" })
    })

  it("GitHub: proves the user can access the installation and records only the user's repositories", async () => {
    const r = await github.complete(e, ghLink({ repos: ["manaflow-ai/cmux", "manaflow-ai/hq"] }).http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy: userScope })
    expect(r).toMatchObject({
      account: { key: "github:installation:42", name: "manaflow-ai" },
      scopes_granted: ["issues:write"],
      credential: { kind: "github_installation", installation_id: 42 },
      resources: { repos: ["manaflow-ai/cmux", "manaflow-ai/hq"] }
    })
    const whole = await github.complete(e, ghLink().http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy: { githubScope: "installation", requireOrgAdmin: false } })
    expect(whole.resources).toEqual({ repos: null })
    await expect(github.complete(e, ghLink({ installations: { installations: [{ id: 7 }] } }).http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy: userScope })).rejects.toThrow(/cannot access/)
    await expect(github.complete(e, ghLink().http, { installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy: userScope })).rejects.toThrow(/no installation_id or code/)
  })

  it("GitHub: require_org_admin refuses a member and accepts an admin", async () => {
    const policy = { githubScope: "linking_user_repos" as const, requireOrgAdmin: true }
    await expect(github.complete(e, ghLink({ role: "member" }).http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy })).rejects.toThrow(/organization admin/)
    expect((await github.complete(e, ghLink({ role: "admin" }).http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy })).account.key).toBe("github:installation:42")
  })

  it("GitHub: comments with a minted installation token signed by the App key", async () => {
    const f = fakeHttp({
      "https://api.github.com/app/installations/42/access_tokens": (req) => {
        expect(req.headers.get("authorization")).toMatch(/^Bearer ey/)
        return ok({ token: "ghs_inst", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201)
      },
      "https://api.github.com/repos/manaflow-ai/cmux/issues/9/comments": () => ok({ id: 1, html_url: "https://github.com/c/1" }, 201)
    })
    const r = await github.call(e, f.http, { kind: "github_installation", installation_id: 42 }, "github.issue.comment", { repo: "manaflow-ai/cmux", issue: 9, body: "hi" })
    expect(r.value).toEqual({ id: 1, url: "https://github.com/c/1" })
    expect(f.calls.at(-1)!.auth).toBe("Bearer ghs_inst")
  })

  it("Linear: refresh returns a new credential only when expired; the call uses what it is given", async () => {
    const f = fakeHttp({
      "https://api.linear.app/oauth/token": (req) => {
        expect(req.headers.get("content-type")).toBe("application/x-www-form-urlencoded")
        return ok({ access_token: "lin_new", refresh_token: "lin_r2", expires_in: 86399 })
      },
      "https://api.linear.app/graphql": () => ok({ data: { issueCreate: { success: true, issue: { id: "i", identifier: "ENG-1", url: "u" } } } })
    })
    expect(await linear.refresh!(e, f.http, { kind: "oauth", access_token: "a", refresh_token: "r", expires_at: Date.now() + 3600_000 })).toBeUndefined()
    const fresh = await linear.refresh!(e, f.http, { kind: "oauth", access_token: "lin_old", refresh_token: "lin_r1", expires_at: Date.now() - 1 })
    expect(fresh).toMatchObject({ access_token: "lin_new", refresh_token: "lin_r2" })
    const r = await linear.call(e, f.http, fresh!, "linear.issue.create", { team_id: "t", title: "x" })
    expect(r.value).toMatchObject({ identifier: "ENG-1" })
    expect(f.calls.at(-1)!.auth).toBe("Bearer lin_new")
  })

  it("an effect call that fails with 5xx or in flight is indeterminate; 429 is retryable", async () => {
    const five = fakeHttp({ "https://slack.com/api/chat.postMessage": () => new Response("bad gateway", { status: 502 }) })
    await expect(slack.call(e, five.http, { kind: "oauth", access_token: "x" }, "slack.post_as_bot", { channel: "C1", text: "x" })).rejects.toMatchObject({ code: "mutation.indeterminate", retryable: false })
    const thrown: Http = async () => {
      throw new Error("connection reset")
    }
    await expect(slack.call(e, thrown, { kind: "oauth", access_token: "x" }, "slack.post_as_bot", { channel: "C1", text: "x" })).rejects.toMatchObject({ code: "mutation.indeterminate" })
    const limited = fakeHttp({ "https://slack.com/api/chat.postMessage": () => new Response("slow down", { status: 429 }) })
    await expect(slack.call(e, limited.http, { kind: "oauth", access_token: "x" }, "slack.post_as_bot", { channel: "C1", text: "x" })).rejects.toMatchObject({ code: "provider.error", retryable: true })
  })

  it("Slack: invalid_auth means the connection needs re-authorization", async () => {
    const f = fakeHttp({ "https://slack.com/api/chat.postMessage": () => ok({ ok: false, error: "invalid_auth" }) })
    await expect(slack.call(e, f.http, { kind: "oauth", access_token: "xoxb" }, "slack.post_as_bot", { channel: "C1", text: "x" })).rejects.toMatchObject({ code: "needs_reauth" })
  })
})

describe("connections end to end (workerd)", () => {
  it("connects Slack, keeps the token sealed, posts as the bot once per key, routes webhooks to event triggers, and revokes", async () => {
    const { token, team } = await signedIn("conn-user-1")
    const providersList = await read(token, "integration.list")
    expect(providersList.json.value.providers).toEqual(expect.arrayContaining([{ provider: "slack", configured: true }]))

    const connect = await op(token, "integration.connect", { provider: "slack", sharing: "team" })
    expect(connect.json.ok).toBe(true)
    const conn = connect.json.value.connection.id as string
    expect(connect.json.value.connection.status).toBe("pending")
    const url = new URL(connect.json.value.authorize_url as string)
    expect(url.origin + url.pathname).toBe("https://slack.com/oauth/v2/authorize")
    expect(url.searchParams.get("redirect_uri")).toBe("http://localhost:3010/integrations/callback")
    const state = url.searchParams.get("state")!

    // Another user cannot finish this connection with the leaked link (login CSRF).
    const mallory = await signedIn("conn-mallory")
    const stolen = await op(mallory.token, "integration.complete", { state, code: "c" })
    expect(stolen.json).toMatchObject({ ok: false, error: { code: "integration.state_invalid" } })

    const fake = fakeHttp({
      "https://slack.com/api/oauth.v2.access": () => ok({ ok: true, access_token: "xoxb-very-secret", scope: "chat:write,app_mentions:read", team: { id: "T0SLACK", name: "Acme" } }),
      "https://slack.com/api/chat.postMessage": () => ok({ ok: true, channel: "C1", ts: "1.2" })
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "slack-code" })
    expect(done.json).toMatchObject({ ok: true, value: { id: conn, status: "active", account: { key: "slack:team:T0SLACK", name: "Acme" } } })

    // The token is only in the sealed credentials table.
    await inDO(connections, async (_i, s) => {
      for (const table of ["own_state", "own_events", "own_ledger", "own_outbox", "external_calls", "credentials"]) {
        expect(JSON.stringify(s.storage.sql.exec(`SELECT * FROM ${table}`).toArray())).not.toContain("xoxb-very-secret")
      }
      expect(s.storage.sql.exec("SELECT generation FROM credentials").toArray()).toHaveLength(1)
    })
    const listed = await read(token, "integration.list")
    expect(JSON.stringify(listed.json)).not.toContain("xoxb")

    const post = await op(token, "slack.post_as_bot", { connection: conn, channel: "C1", text: "hello" }, "post-1")
    expect(post.json).toMatchObject({ ok: true, value: { channel: "C1", ts: "1.2" } })
    const again = await op(token, "slack.post_as_bot", { connection: conn, channel: "C1", text: "hello" }, "post-1")
    expect(again.json).toMatchObject({ ok: true, replayed: true })
    expect(fake.calls.filter((c) => c.url.includes("chat.postMessage"))).toHaveLength(1)
    expect(fake.calls.find((c) => c.url.includes("chat.postMessage"))!.auth).toBe("Bearer xoxb-very-secret")
    expect((await op(token, "slack.post_as_bot", { connection: conn, channel: "C1", text: "other" }, "post-1")).json.error.code).toBe("idempotency.conflict")

    // Webhook: an event trigger on this connection gets one run per Slack event id.
    const auto = await op(token, "automation.create", {
      name: "on mention",
      triggers: [{ type: "event", source: "integration", connection: conn, event: "app_mention" }],
      body: { type: "steps", steps: [{ type: "note", text: "mentioned" }] }
    })
    expect(auto.json.value.triggers[0].status).toBe("active")
    const slackHook = async (body: string) => {
      const ts = String(Math.floor(Date.now() / 1000))
      const res = await worker.fetch("https://api.test/v1/hooks/slack", {
        method: "POST",
        headers: { "content-type": "application/json", "x-slack-request-timestamp": ts, "x-slack-signature": `v0=${await hmac(testEnv.SLACK_SIGNING_SECRET, `v0:${ts}:${body}`)}` },
        body
      })
      return { status: res.status, json: (await res.json()) as any }
    }
    const event = JSON.stringify({ type: "event_callback", team_id: "T0SLACK", event_id: "Ev01", event: { type: "app_mention", text: "<@bot> hi" } })
    expect((await slackHook(event)).json).toMatchObject({ ok: true, connections: 1, runs: 1 })
    expect((await slackHook(event)).json).toMatchObject({ ok: true, runs: 0 })
    const other = JSON.stringify({ type: "event_callback", team_id: "T0SLACK", event_id: "Ev02", event: { type: "message" } })
    expect((await slackHook(other)).json.runs).toBe(0)
    const runs = await read(token, "automation.runs.list", { automation: auto.json.value.id })
    expect(runs.json.value.runs).toHaveLength(1)
    expect(runs.json.value.runs[0].trigger).toMatchObject({ type: "event", delivery_id: `${conn}:Ev01` })

    // Revoke: credential gone at once, calls refused, webhooks dropped.
    const revoke = await op(token, "integration.revoke", { connection: conn })
    expect(revoke.json.value.status).toBe("revoked")
    await inDO(connections, async (_i, s) => {
      expect(s.storage.sql.exec("SELECT * FROM credentials").toArray()).toHaveLength(0)
    })
    expect((await op(token, "slack.post_as_bot", { connection: conn, channel: "C1", text: "after" })).json.error.code).toBe("integration.unavailable")
    const late = JSON.stringify({ type: "event_callback", team_id: "T0SLACK", event_id: "Ev03", event: { type: "app_mention" } })
    expect((await slackHook(late)).json.runs).toBe(0)
  })

  it("connects Linear (account key of real length), refreshes once for concurrent calls, and keeps a 5xx effect indeterminate", async () => {
    const { token, team } = await signedIn("conn-linear-1")
    const connect = await op(token, "integration.connect", { provider: "linear" })
    const conn = connect.json.value.connection.id as string
    const state = new URL(connect.json.value.authorize_url).searchParams.get("state")!
    let refreshes = 0
    let graphqlStatus = 200
    const fake = fakeHttp({
      "https://api.linear.app/oauth/token": async (req) => {
        const body = new URLSearchParams(await req.text())
        if (body.get("grant_type") === "refresh_token") {
          refreshes++
          return ok({ access_token: `lin_refreshed_${refreshes}`, refresh_token: `lin_r_${refreshes + 1}`, expires_in: 86399 })
        }
        // Expired at once, so the first provider call must refresh.
        return ok({ access_token: "lin_first", refresh_token: "lin_r_1", expires_in: 0, scope: "read write" })
      },
      "https://api.linear.app/graphql": async (req) => {
        const q = (await req.json()) as { query: string }
        if (q.query.includes("viewer")) return ok({ data: { viewer: { organization: { id: "8f6e1c2a-5b7d-4e3f-9a1b-2c3d4e5f6a7b", name: "Acme", urlKey: "acme" } } } })
        if (q.query.includes("teams")) return ok({ data: { teams: { nodes: [{ id: "team-uuid-1", key: "ENG", name: "Engineering" }] } } })
        if (graphqlStatus !== 200) return new Response("oops", { status: graphqlStatus })
        return ok({ data: { issueCreate: { success: true, issue: { id: "i1", identifier: "ENG-1", url: "https://linear.app/acme/issue/ENG-1" } } } })
      }
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "lin-code" })
    expect(done.json).toMatchObject({ ok: true, value: { status: "active", account: { key: "linear:org:8f6e1c2a-5b7d-4e3f-9a1b-2c3d4e5f6a7b" } } })

    // A provider read: no idempotency key, answered with the stored token.
    const teams = await read(token, "linear.teams.list", { connection: conn })
    expect(teams.json.value).toEqual({ teams: [{ id: "team-uuid-1", key: "ENG", name: "Engineering" }] })
    const params = { connection: conn, team_id: "team-1", title: "From cmux" }
    const [a, b] = await Promise.all([op(token, "linear.issue.create", params), op(token, "linear.issue.create", { ...params, title: "Second" })])
    expect(a.json.ok && b.json.ok).toBe(true)
    expect(refreshes).toBe(1) // the teams read above refreshed once; the two concurrent creates reuse it

    graphqlStatus = 502
    const flaky = await op(token, "linear.issue.create", params, "lin-5xx")
    expect(flaky.json).toMatchObject({ ok: false, error: { code: "mutation.indeterminate", retryable: false } })
    graphqlStatus = 200
    // The key stays decided: a retry replays the indeterminate answer instead of creating a second issue.
    const retry = await op(token, "linear.issue.create", params, "lin-5xx")
    expect(retry.json).toMatchObject({ ok: false, replayed: true, error: { code: "mutation.indeterminate" } })
  })

  it("GitHub team policy: ops and webhooks stay inside the linking user's repositories and the allowlist; managed policies lock", async () => {
    const { token, team } = await signedIn("conn-gh-1")
    const connect = await op(token, "integration.connect", { provider: "github", sharing: "team" })
    const conn = connect.json.value.connection.id as string
    const url = new URL(connect.json.value.authorize_url)
    expect(url.origin + url.pathname).toBe("https://github.com/apps/cmux-test/installations/new")
    const state = url.searchParams.get("state")!
    const posts: Array<string> = []
    const fake = fakeHttp({
      "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
      "https://api.github.com/user/installations/99/repositories": () => ok({ repositories: [{ full_name: "acme/web" }, { full_name: "acme/api" }] }),
      "https://api.github.com/user/installations": () => ok({ installations: [{ id: 99, account: { login: "acme", type: "Organization" }, permissions: { issues: "write" } }] }),
      "https://api.github.com/app/installations/99/access_tokens": () => ok({ token: "ghs_x", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201),
      "https://api.github.com/repos/": (req) => {
        posts.push(new URL(req.url).pathname)
        return ok({ id: 1, html_url: "https://github.com/c" }, 201)
      }
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })
    expect(done.json).toMatchObject({ ok: true, value: { status: "active", resources: { repos: ["acme/api", "acme/web"] } } })

    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/web", issue: 1, body: "hi" })).json.ok).toBe(true)
    const outside = await op(token, "github.issue.comment", { connection: conn, repo: "acme/secret", issue: 1, body: "hi" })
    expect(outside.json).toMatchObject({ ok: false, error: { code: "policy.denied" } })

    // The allowlist narrows further at call time.
    const set = await op(token, "integration.policy.set", { github: { repo_allowlist: ["acme/api"] } })
    expect(set.json.value).toMatchObject({ source: "admin", locked: false, github: { scope: "linking_user_repos", repo_allowlist: ["acme/api"] } })
    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/web", issue: 2, body: "hi" })).json.error.code).toBe("policy.denied")
    expect(posts).toEqual(["/repos/acme/web/issues/1/comments"])

    // Webhooks from repositories outside the scope start nothing.
    const auto = await op(token, "automation.create", { name: "on push", triggers: [{ type: "event", source: "integration", connection: conn, event: "push" }], body: { type: "steps", steps: [{ type: "note", text: "x" }] } })
    const ghHook = async (repo: string) => {
      const body = JSON.stringify({ installation: { id: 99 }, repository: { full_name: repo }, after: crypto.randomUUID() })
      const res = await worker.fetch("https://api.test/v1/hooks/github", {
        method: "POST",
        headers: { "x-hub-signature-256": `sha256=${await hmac(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": "push" },
        body
      })
      return (await res.json()) as any
    }
    expect((await ghHook("acme/api")).runs).toBe(1)
    expect((await ghHook("acme/web")).runs).toBe(0)
    expect((await ghHook("other/repo")).runs).toBe(0)
    expect((await read(token, "automation.runs.list", { automation: auto.json.value.id })).json.value.runs).toHaveLength(1)

    // An MDM-managed policy replaces and locks the admin policy.
    await inDO(connections, async (instance) => {
      instance.submitSystem("integration.policy.apply_managed", { source: "mdm", policy: { allowed_providers: ["github"], github: { require_org_admin: true } }, applied_by: "mdm-profile-1" }, "mdm-1")
    })
    const got = await read(token, "integration.policy.get")
    expect(got.json.value).toMatchObject({ source: "mdm", locked: true, allowed_providers: ["github"], github: { require_org_admin: true, repo_allowlist: null } })
    expect((await op(token, "integration.policy.set", { github: { repo_allowlist: null } })).json.error.code).toBe("policy.locked")
    expect((await op(token, "integration.connect", { provider: "slack" })).json.error.code).toBe("policy.denied")
    // Path segments like ".." never reach the GitHub URL.
    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/..", issue: 1, body: "x" })).json.error.code).toBe("validation.invalid")
    // Managed sources cannot be claimed over the API.
    expect((await op(token, "integration.policy.apply_managed", { source: "sso", policy: {}, applied_by: "me" })).status).toBe(400)
  })

  it("a stricter policy narrows existing connections: installation-scope links and denied providers stop working", async () => {
    const { token, team } = await signedIn("conn-gh-2")
    await op(token, "integration.policy.set", { github: { scope: "installation" } })
    const connect = await op(token, "integration.connect", { provider: "github" })
    const conn = connect.json.value.connection.id as string
    const state = new URL(connect.json.value.authorize_url).searchParams.get("state")!
    const fake = fakeHttp({
      "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
      "https://api.github.com/user/installations": () => ok({ installations: [{ id: 77, account: { login: "acme", type: "Organization" } }] }),
      "https://api.github.com/app/installations/77/access_tokens": () => ok({ token: "ghs_x", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201),
      "https://api.github.com/repos/": () => ok({ id: 1 }, 201)
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "c", installation_id: "77" })
    expect(done.json.value.resources).toEqual({ repos: null })
    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/any", issue: 1, body: "x" })).json.ok).toBe(true)
    await op(token, "integration.policy.set", { github: { scope: "linking_user_repos" } })
    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/any", issue: 2, body: "x" })).json.error.code).toBe("policy.denied")
    await op(token, "integration.policy.set", { github: { scope: "installation" } })
    await op(token, "integration.policy.set", { allowed_providers: ["slack"] })
    expect((await op(token, "github.issue.comment", { connection: conn, repo: "acme/any", issue: 3, body: "x" })).json.error.code).toBe("policy.denied")
  })

  it("GitHub: more than 1000 accessible repositories refuses the link instead of truncating", async () => {
    const full = { repositories: Array.from({ length: 100 }, (_, i) => ({ full_name: `acme/r${i}` })) }
    const f = fakeHttp({
      "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
      "https://api.github.com/user/installations/42/repositories": () => ok(full),
      "https://api.github.com/user/installations": () => ok({ installations: [{ id: 42, account: { login: "acme", type: "Organization" } }] })
    })
    await expect(github.complete(testEnv as any, f.http, { code: "c", installation_id: "42", redirectUri: "x", connection: "conn_test", state: "st", scopes_requested: [], policy: { githubScope: "linking_user_repos", requireOrgAdmin: false } })).rejects.toThrow(/more than 1000/)
  })

  it("pending connections expire once after 30 minutes from the alarm, even after a restart; late callbacks are refused; active ones are untouched", async () => {
    const { token, team } = await signedIn("conn-expire-1")
    const TTL = 30 * 60_000
    // One active connection (linked), one pending that will expire.
    const a = await op(token, "integration.connect", { provider: "slack" })
    const activeId = a.json.value.connection.id as string
    const activeState = new URL(a.json.value.authorize_url).searchParams.get("state")!
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fakeHttp({ "https://slack.com/api/oauth.v2.access": () => ok({ ok: true, access_token: "xoxb-e", scope: "chat:write", team: { id: "TEXP", name: "Exp" } }) }).http
    })
    expect((await op(token, "integration.complete", { state: activeState, code: "c" })).json.value.status).toBe("active")
    const p = await op(token, "integration.connect", { provider: "slack" })
    const pendingId = p.json.value.connection.id as string
    const pendingState = new URL(p.json.value.authorize_url).searchParams.get("state")!

    let createdAt = 0
    await inDO(connections, async (instance) => {
      createdAt = instance.boundEngine.currentState.connections[pendingId].created_at
      // The alarm targets exactly the oldest pending expiry.
      expect(instance.nextWakeAt(instance.boundEngine.currentState, Date.now())).toBe(createdAt + TTL)
      await instance.onWake(createdAt + TTL - 1)
      expect(instance.boundEngine.currentState.connections[pendingId].status).toBe("pending")
    })
    // A restarted object keeps the same wake time (it comes from committed state).
    await evictDurableObject(connections as never)
    await inDO(connections, async (instance) => {
      expect(instance.nextWakeAt(instance.boundEngine.currentState, Date.now())).toBe(createdAt + TTL)
      await instance.onWake(createdAt + TTL)
      const seq = instance.boundEngine.currentSeq
      expect(instance.boundEngine.currentState.connections[pendingId].status).toBe("expired")
      // A second wake for the same slot changes nothing (deterministic key, state check).
      await instance.onWake(createdAt + TTL + 5)
      expect(instance.boundEngine.currentSeq).toBe(seq)
      expect(instance.boundEngine.currentState.connections[activeId].status).toBe("active")
      expect(instance.nextWakeAt(instance.boundEngine.currentState, Date.now()) === null || instance.nextWakeAt(instance.boundEngine.currentState, Date.now()) > createdAt + TTL).toBe(true)
    })
    // The provider redirect for the expired attempt is refused before any provider call.
    const late = await op(token, "integration.complete", { state: pendingState, code: "c2" })
    expect(late.json).toMatchObject({ ok: false, error: { code: "integration.state_invalid" } })
    expect(late.json.error.message).toMatch(/expired/)
    const listed = (await read(token, "integration.list")).json.value.connections
    expect(listed.find((c: any) => c.id === pendingId).status).toBe("expired")
    expect(listed.find((c: any) => c.id === activeId).status).toBe("active")
    // A day later the expired attempt leaves owner state (the projection keeps its row); the active one stays.
    await inDO(connections, async (instance) => {
      const expiredAt = instance.boundEngine.currentState.connections[pendingId].updated_at
      expect(instance.nextWakeAt(instance.boundEngine.currentState, Date.now())).toBe(expiredAt + 24 * 3600_000)
      await instance.onWake(expiredAt + 24 * 3600_000)
      expect(instance.boundEngine.currentState.connections[pendingId]).toBeUndefined()
      expect(instance.boundEngine.currentState.connections[activeId].status).toBe("active")
    })
  })

  it("a refused expiry is recorded and never retried, so it cannot spin the alarm", async () => {
    const { token, team } = await signedIn("conn-expire-2")
    const p = await op(token, "integration.connect", { provider: "slack" })
    const id = p.json.value.connection.id as string
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance, state) => {
      const created = instance.boundEngine.currentState.connections[id].created_at
      // Burn the key with other params so the real expire is refused (idempotency.conflict).
      instance.submitSystem("connection.expire", { connection: id, at: 0 }, `expire:${id}`)
      await instance.onWake(created + 30 * 60_000)
      expect(instance.boundEngine.currentState.connections[id].status).toBe("pending")
      expect(state.storage.sql.exec("SELECT key FROM refused_system_ops").toArray().map((r: any) => r.key)).toEqual([`expire:${id}`])
      const next = instance.nextWakeAt(instance.boundEngine.currentState, Date.now())
      expect(next === null || next > created + 30 * 60_000).toBe(true)
    })
  })

  it("refuses forged provider webhooks and answers Slack URL verification", async () => {
    const body = JSON.stringify({ type: "url_verification", challenge: "abc" })
    const ts = String(Math.floor(Date.now() / 1000))
    const good = await worker.fetch("https://api.test/v1/hooks/slack", { method: "POST", headers: { "x-slack-request-timestamp": ts, "x-slack-signature": `v0=${await hmac(testEnv.SLACK_SIGNING_SECRET, `v0:${ts}:${body}`)}` }, body })
    expect(await good.json()).toEqual({ challenge: "abc" })
    const forged = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": "sha256=00", "x-github-delivery": "d", "x-github-event": "push" }, body: "{}" })
    expect(forged.status).toBe(401)
  })

  it("install tokens without a send-external grant cannot post; private connections stay private", async () => {
    const { token, user } = await signedIn("conn-user-2")
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
    const reg = await op(token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: "cli", device_name: "laptop", platform: "macos" })
    const install = reg.json.value.id as string
    const ch = (await worker.fetch("https://api.test/v1/auth/challenge", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install }) }).then((r) => r.json())) as any
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`)))
    const b64u = btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const tok = (await worker.fetch("https://api.test/v1/auth/token", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ user, install, nonce: ch.nonce, signature: b64u }) }).then((r) => r.json())) as any
    const jwt = tok.access_token as string
    const c = await op(token, "integration.connect", { provider: "slack" })
    const conn = c.json.value.connection.id as string
    const post = await op(jwt, "slack.post_as_bot", { connection: conn, channel: "C1", text: "x" })
    expect(post.json).toMatchObject({ ok: false, error: { code: "auth.forbidden" } })
    expect(post.json.error.message).toMatch(/send-external/)
    // integration.connect is session-only (a human approves in the provider anyway).
    expect((await op(jwt, "integration.connect", { provider: "slack" })).json.error.code).toBe("auth.forbidden")
    // The install lists this user's private connection; another user's session does not see it.
    expect((await read(jwt, "integration.list")).json.value.connections.map((x: any) => x.id)).toEqual([conn])
    const stranger = await signedIn("conn-user-3")
    expect((await read(stranger.token, "integration.list")).json.value.connections).toEqual([])
  })
})
