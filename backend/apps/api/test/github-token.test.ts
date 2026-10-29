import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, post, signedInWithInstall, SIZE, vmKey, WG_KEY, worker } from "./cloud-bind-support.ts"
import { settlePolicy } from "./integration-policy-settle.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { githubRepos } from "../src/integrations/github-tokens.ts"
import type { Env } from "../src/env.ts"
import type { ConnectionsState } from "../src/domains/connections.ts"
import type { Connection } from "@cmux/protocol"
import type { Principal } from "@cmux/ownership"

/**
 * POST /v1/integrations/github/token, /token/revoke and GET /status (gh-app-product contract):
 * a narrowed, per-principal installation token from the team's GitHub connection, its sealed
 * ledger, revocation (route and install revoke) and the team audit record. GitHub is faked.
 */

const testEnv = env as unknown as Record<string, any>
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const op = (token: string, name: string, params: unknown) => post("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => post("/v1/read", token, { op: name, params })
const asJson = (r: { status: number; body: any }) => ({ status: r.status, json: r.body })
const policy = (token: string, team: string, fields: unknown) => settlePolicy((t, n, p) => op(t, n, p).then(asJson), (t, n, p) => read(t, n, p).then(asJson), token, team, fields)
const token = (bearer: string, body: unknown) => post("/v1/integrations/github/token", bearer, body)

/** A fake GitHub: the App's installation 99 on account acme; records every request. */
const fakeGitHub = () => {
  const calls: Array<{ method: string; url: string; auth: string | null; body: string }> = []
  let n = 0
  const routes: Record<string, (req: Request, body: string) => Response> = {
    "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
    "https://api.github.com/user/installations/99/repositories": () => ok({ repositories: [{ full_name: "acme/web" }, { full_name: "acme/api" }] }),
    "https://api.github.com/user/installations": () => ok({ installations: [{ id: 99, account: { login: "acme", type: "Organization" }, permissions: { contents: "write", pull_requests: "write", issues: "write", workflows: "write", metadata: "read" } }] }),
    "https://api.github.com/app/installations/99/access_tokens": (_req, body) =>
      ok({ token: `ghs_secret_${++n}`, expires_at: new Date(Date.now() + 3600_000).toISOString(), permissions: { ...(JSON.parse(body || "{}") as { permissions?: object }).permissions, metadata: "read" } }, 201),
    "https://api.github.com/installation/token": () => new Response(null, { status: 204 })
  }
  const http = async (req: Request) => {
    const body = await req.clone().text()
    calls.push({ method: req.method, url: req.url, auth: req.headers.get("authorization"), body })
    const key = Object.keys(routes).find((k) => req.url.startsWith(k))
    return key ? routes[key]!(req, body) : new Response("not found", { status: 404 })
  }
  return { http, calls, routes, mints: () => calls.filter((c) => c.url.endsWith("/access_tokens")), deletes: () => calls.filter((c) => c.method === "DELETE") }
}

/** Links a team-shared GitHub connection (installation 99, repos acme/web and acme/api) in `team`. */
const linkGitHub = async (session: string, team: string) => {
  const gh = fakeGitHub()
  await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (instance) => void (instance.http = gh.http))
  const connect = await op(session, "integration.connect", { provider: "github", sharing: "team" })
  const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
  const done = await op(session, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })
  expect(done.body, JSON.stringify(done.body)).toMatchObject({ ok: true, value: { status: "active" } })
  return { gh }
}

describe("GitHub token endpoint", { timeout: 60_000 }, () => {
  it("mints a token narrowed to one repository and the asked permissions, reuses it per principal, never across principals", async () => {
    const a = await signedInWithInstall("gh-token-1", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const ask = { team: a.team, repo: "acme/web", permissions: { pull_requests: "write", contents: "write" }, label: "lane-1" }
    const first = await token(a.installToken, ask)
    expect(first.body, JSON.stringify(first.body)).toMatchObject({ token: "ghs_secret_1", repo: "acme/web", permissions: { contents: "write", pull_requests: "write", metadata: "read" } })
    expect([/^[0-9a-f]{16}$/.test(first.body.token_id), Date.parse(first.body.expires_at) > Date.now() + 50 * 60_000]).toEqual([true, true])
    // The request body narrows to the repository name and exactly these permissions.
    expect([JSON.parse(gh.mints()[0]!.body), gh.mints()[0]!.auth?.slice(0, 9)]).toEqual([{ repositories: ["web"], permissions: { contents: "write", pull_requests: "write" } }, "Bearer ey"])

    // Same principal, same ask: the ledger answers. Another principal (the person's session) or other permissions: another token.
    const again = [await token(a.installToken, { ...ask, label: "lane-2" }), await token(a.session, ask), await token(a.installToken, { ...ask, permissions: { contents: "read" } })]
    expect([...again.map((r) => r.body.token), gh.mints().length]).toEqual(["ghs_secret_1", "ghs_secret_2", "ghs_secret_3", 3])

    // The ledger holds the token sealed, never in the clear.
    await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)), async (instance) => {
      const rows = instance.ctx.storage.sql.exec("SELECT * FROM github_tokens").toArray() as Array<Record<string, unknown>>
      expect([rows.length, JSON.stringify(rows).includes("ghs_secret")]).toEqual([3, false])
      expect(rows.map((r) => r.principal).sort()).toEqual([`install:${a.install}`, `install:${a.install}`, `session:${a.user}`])
    })

    // The team audit records each mint by token_id, never the token.
    let audit: Array<any> = []
    for (let i = 0; i < 20 && audit.length < 3; i++) {
      await fireAlarm(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team)))
      audit = ((await read(a.session, "team.audit.list", {})).body.value?.entries ?? []).filter((e: any) => e.op === "team.github.token_minted")
    }
    expect(audit.find((e) => e.detail.token_id === first.body.token_id).detail).toMatchObject({ principal_kind: "cli", install: a.install, label: "lane-1", repo: "acme/web" })
    expect(JSON.stringify(audit)).not.toContain("ghs_secret")

    // Status: configured, the connection and its repositories.
    const res = await worker.fetch(`https://api.test/v1/integrations/github/status?team=${a.team}`, { headers: { authorization: `Bearer ${a.installToken}` } })
    expect(await res.json()).toMatchObject({ configured: true, app_slug: "cmux-test", connection: { account: "acme", status: "active", repos: ["acme/api", "acme/web"], allow_workflows: false } })
  })

  it("pins a GitHub token to the exact selected link and never changes accounts on revoke", async () => {
    const a = await signedInWithInstall("gh-token-selected", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const original = ((await read(a.session, "integration.list")).body.value.connections as Array<{ id: string; provider: string }>).find(
      (c) => c.provider === "github",
    )!.id

    // A second active link to the same installation must never act as an implicit fallback.
    const begin = await op(a.session, "integration.connect", { provider: "github", sharing: "team" })
    const oauthState = new URL(begin.body.value.authorize_url).searchParams.get("state")!
    const completed = await op(a.session, "integration.complete", {
      state: oauthState, code: "c", installation_id: "99", setup_action: "install",
    })
    expect(completed.body.value.status).toBe("active")
    const another = completed.body.value.id as string
    expect(another).not.toBe(original)

    const ask = { team: a.team, repo: "acme/web", permissions: { contents: "read" } }
    const selected = await token(a.session, { ...ask, connection: original })
    expect(selected.status).toBe(200)
    expect(selected.body.connection_id).toBe(original)
    const second = await token(a.session, { ...ask, connection: another })
    expect(second.status).toBe(200)
    expect(second.body.connection_id).toBe(another)
    // Distinct connection IDs create distinct sealed cache identities even for the same installation/repo.
    expect(second.body.token).not.toBe(selected.body.token)
    expect(gh.mints()).toHaveLength(2)
    const again = await token(a.session, { ...ask, connection: original })
    expect([again.body.token, again.body.connection_id, gh.mints().length]).toEqual([selected.body.token, original, 2])

    const invalid = await token(a.session, { ...ask, connection: "conn_00000000000000000000" })
    expect([invalid.status, invalid.body.error?.code, gh.mints().length]).toEqual([404, "integration.not_found", 2])
    const malformed = await token(a.session, { ...ask, connection: "not-a-connection" })
    expect([malformed.status, malformed.body.error?.code, gh.mints().length]).toEqual([400, "request.invalid", 2])

    expect((await op(a.session, "integration.revoke", { connection: original })).body.value.status).toBe("revoked")
    const revoked = await token(a.session, { ...ask, connection: original })
    expect([revoked.status, revoked.body.error?.code, gh.mints().length]).toEqual([404, "integration.not_found", 2])
    const stillLive = await token(a.session, { ...ask, connection: another })
    expect([stillLive.status, stillLive.body.connection_id]).toEqual([200, another])
    // Legacy callers without a selection may still use an authorized active connection.
    const legacy = await token(a.session, ask)
    expect([legacy.status, legacy.body.connection_id]).toEqual([200, another])
  })

  it("pins repository pagination to the selected connection and refuses a stale account list", async () => {
    const firstId = "conn_01234567890123456789"
    const secondId = "conn_98765432109876543210"
    const connection = (id: string, installation: number): Connection => ({
      id,
      owner: "team_fixture",
      created_by: "user_fixture",
      provider: "github",
      account: { key: `github:installation:${installation}`, name: "acme" },
      scopes_requested: [],
      scopes_granted: [],
      status: "active",
      sharing: "team",
      resources: { repos: ["acme/web", "acme/api"] },
      created_at: 1,
      updated_at: 1,
    })
    let state: ConnectionsState = {
      owner: "team_fixture",
      connections: { [firstId]: connection(firstId, 901), [secondId]: connection(secondId, 902) },
    }
    const principal = { kind: "session", user: "user_fixture", team: "team_fixture", identity: "session:user_fixture" } as Principal
    const host = {
      env: testEnv as Env,
      state: () => state,
      http: async (request: Request): Promise<Response> => {
        if (request.url.endsWith("/access_tokens"))
          return ok({ token: "synthetic_installation_token", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201)
        if (request.url.startsWith("https://api.github.com/installation/repositories?"))
          return ok({
            repositories: Array.from({ length: 100 }, (_, i) => ({
              full_name: i % 2 ? "acme/web" : "acme/api",
              private: true,
            })),
            total_count: 101,
          })
        return new Response("unexpected synthetic endpoint", { status: 404 })
      },
    }
    const first = await githubRepos(host, principal, {})
    if (!first.ok) throw new Error(`synthetic repository-list fixture failed: ${first.code}`)
    expect(first.ok).toBe(true)
    expect(first.value.repos).toHaveLength(100)
    const selected = first.value.repos[0]!.connection_id
    expect(first.value.repos.every((repo) => repo.connection_id === selected)).toBe(true)
    expect(typeof first.value.cursor).toBe("string")

    const next = await githubRepos(host, principal, { cursor: first.value.cursor! })
    expect(next.ok).toBe(true)
    if (!next.ok) throw new Error(next.message)
    expect(next.value.repos.every((repo) => repo.connection_id === selected)).toBe(true)

    const differentSearch = await githubRepos(host, principal, { cursor: first.value.cursor!, query: "other" })
    expect(differentSearch.ok).toBe(false)
    if (!differentSearch.ok) expect([differentSearch.status, differentSearch.code]).toEqual([409, "cursor_stale"])

    state = {
      ...state,
      connections: {
        ...state.connections,
        [selected]: { ...state.connections[selected]!, status: "revoked", updated_at: 2 },
      },
    }
    const stale = await githubRepos(host, principal, { cursor: first.value.cursor! })
    expect(stale.ok).toBe(false)
    if (!stale.ok) expect([stale.status, stale.code]).toEqual([409, "cursor_stale"])

    const oversized = await githubRepos(host, principal, { cursor: "x".repeat(2048) })
    expect(oversized.ok).toBe(false)
    if (!oversized.ok) expect([oversized.status, oversized.code]).toEqual([400, "request.invalid"])
  })

  it("refuses repositories outside the connection or policy, other owners, unknown permissions and workflows without the policy flag", async () => {
    const a = await signedInWithInstall("gh-token-2", "cli")
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("integration.not_found")
    const { gh } = await linkGitHub(a.session, a.team)
    const t = (repo: string, permissions: unknown) => token(a.installToken, { team: a.team, repo, permissions }).then((r) => [r.status, r.body.error?.code])
    expect(await t("acme/secret", { contents: "read" })).toEqual([403, "policy.denied"])
    expect(await t("other/web", { contents: "read" })).toEqual([403, "policy.denied"])
    expect(await t("acme/web", { administration: "write" })).toEqual([400, "request.invalid"])
    expect(await t("acme/web", { contents: "admin" })).toEqual([400, "request.invalid"])
    expect(await t("acme/web", {})).toEqual([400, "request.invalid"])
    expect(await t("acme/web", { workflows: "write" })).toEqual([403, "policy.denied"])
    expect(gh.mints()).toHaveLength(0)
    await policy(a.session, a.team, { github: { allow_workflows: true } })
    expect(await t("acme/web", { workflows: "write" })).toEqual([200, undefined])
    await policy(a.session, a.team, { github: { repo_allowlist: ["acme/api"] } })
    expect(await t("acme/web", { contents: "read" })).toEqual([403, "policy.denied"])
    // Unauthenticated, and a team the install was not minted for.
    expect((await token("", { team: a.team, repo: "acme/api", permissions: { contents: "read" } })).status).toBe(401)
    expect((await token(a.installToken, { team: "team_00000000000000000000", repo: "acme/api", permissions: { contents: "read" } })).body.error.code).toBe("auth.forbidden")
    // A GitHub refusal (422) is policy.denied.
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "nope" }, 422)
    expect(await t("acme/api", { checks: "write" })).toEqual([403, "policy.denied"])
  })

  it("refuses an elevated, extra, or unverifiable GitHub token grant before handing it to a caller", async () => {
    const a = await signedInWithInstall("gh-token-grant-check", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    const endpoint = "https://api.github.com/app/installations/99/access_tokens"
    const expiresAt = new Date(Date.now() + 3600_000).toISOString()
    const ask = { team: a.team, repo: "acme/web", permissions: { contents: "read" } }
    const invalid = [
      { token: "synthetic_elevated", expires_at: expiresAt, permissions: { contents: "write", metadata: "read" } },
      { token: "synthetic_extra", expires_at: expiresAt, permissions: { contents: "read", issues: "write", metadata: "read" } },
      { token: "synthetic_missing_expiry", permissions: { contents: "read", metadata: "read" } },
    ]
    for (const reply of invalid) {
      gh.routes[endpoint] = () => ok(reply, 201)
      const result = await token(a.session, ask)
      expect(result.status).toBeGreaterThanOrEqual(400)
      expect(JSON.stringify(result.body)).not.toContain(reply.token)
    }
    // The invalid grants never enter a caller's live reusable token cache.
    gh.routes[endpoint] = () => ok({
      token: "synthetic_valid",
      expires_at: expiresAt,
      permissions: { contents: "read", metadata: "read" },
    }, 201)
    const good = await token(a.session, ask)
    expect([good.status, good.body.token]).toEqual([200, "synthetic_valid"])
  })

  it("an uninstalled App answers needs_reauth and marks the connection; GitHub's rate limit answers 429 with retry_after", async () => {
    const a = await signedInWithInstall("gh-token-3", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => new Response(JSON.stringify({ message: "API rate limit exceeded" }), { status: 403, headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Math.floor(Date.now() / 1000) + 30) } })
    const limited = await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })
    expect([limited.status, limited.body.error.code, limited.body.retry_after > 0]).toEqual([429, "rate_limited", true])
    gh.routes["https://api.github.com/app/installations/99/access_tokens"] = () => ok({ message: "Not Found" }, 404)
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("needs_reauth")
    expect((await read(a.session, "integration.list")).body.value.connections.find((c: any) => c.provider === "github").status).toBe("needs_reauth")
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("needs_reauth")
  })

  it("revoke deletes each ledger token at GitHub; an install revoke does too; another install's tokens need a team admin", async () => {
    const a = await signedInWithInstall("gh-token-4", "cli")
    const { gh } = await linkGitHub(a.session, a.team)
    for (const repo of ["acme/web", "acme/api"]) expect((await token(a.installToken, { team: a.team, repo, permissions: { contents: "write" } })).status).toBe(200)
    expect((await post("/v1/integrations/github/token/revoke", a.installToken, { team: a.team })).body).toEqual({ revoked: 2 })
    expect(gh.deletes().map((c) => c.auth).sort()).toEqual(["Bearer ghs_secret_1", "Bearer ghs_secret_2"])
    // A new ask mints anew.
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })).body.token).toBe("ghs_secret_3")
    // The person (owner of the personal team) may revoke the install's tokens from a session.
    expect((await post("/v1/integrations/github/token/revoke", a.session, { team: a.team, install: a.install })).body).toEqual({ revoked: 1 })
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })).body.token).toBe("ghs_secret_4")

    // Revoking the install revokes its live tokens through UserDO's registry (closeInstall).
    expect((await op(a.session, "install.revoke", { install: a.install })).body.ok).toBe(true)
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user))
    for (let i = 0; i < 20 && !gh.deletes().some((c) => c.auth === "Bearer ghs_secret_4"); i++) await fireAlarm(user)
    expect(gh.deletes().map((c) => c.auth)).toContain("Bearer ghs_secret_4")
    // A revoked install gets nothing, cached or new.
    expect((await token(a.installToken, { team: a.team, repo: "acme/web", permissions: { contents: "write" } })).status).toBe(401)
  })

  it("a VM install mints for its own machine's team only; a chief-less phone install is refused", async () => {
    const a = await signedInWithInstall("cloud-ghtoken-1", "mac")
    const { gh } = await linkGitHub(a.session, a.team)
    // A bound machine and its VM install's token (as cloud-vm-install.test.ts makes them).
    const machine = (await op(a.session, "cloud.machine.create", { size: SIZE })).body.value.machine.id as string
    const [{ json }, key] = [await bindFile(cloudStub(a.team), machine), await vmKey()]
    const install = (await post("/v1/cloud/bind", undefined, { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })).body.value.install as { id: string; user: string }
    const ch = (await post("/v1/auth/challenge", undefined, { user: install.user, install: install.id })).body
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, new TextEncoder().encode(`${ch.message_prefix}${ch.nonce}`))
    const signature = btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    const vm = (await post("/v1/auth/token", undefined, { user: install.user, install: install.id, nonce: ch.nonce, signature })).body.access_token as string

    const mine = await token(vm, { repo: "acme/web", permissions: { contents: "read" } })
    expect(mine.body.token, JSON.stringify(mine.body)).toBe("ghs_secret_1")
    expect((await token(vm, { team: "team_00000000000000000000", repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("auth.forbidden")
    // Deleting the machine ends the VM install, and with it the VM's tokens.
    expect((await op(a.session, "cloud.machine.delete", { machine })).body.ok).toBe(true)
    expect((await token(vm, { repo: "acme/web", permissions: { contents: "read" } })).status).toBeGreaterThanOrEqual(401)
    const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user))
    for (let i = 0; i < 20 && !gh.deletes().some((c) => c.auth === `Bearer ${mine.body.token}`); i++) [await fireAlarm(cloudStub(a.team) as unknown), await fireAlarm(user)]
    expect(gh.deletes().map((c) => c.auth)).toContain(`Bearer ${mine.body.token}`)
    const phone = await signedInWithInstall("gh-token-5", "ios")
    expect((await token(phone.installToken, { team: phone.team, repo: "acme/web", permissions: { contents: "read" } })).body.error.code).toBe("auth.forbidden")
  })
})
