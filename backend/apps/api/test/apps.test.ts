import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { beforeAll, describe, expect, it } from "vitest"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default

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
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, opts: { key?: string; origin?: string } = {}) =>
  call("/v1/ops", token, { op: name, params, idempotency_key: opts.key ?? crypto.randomUUID(), origin: opts.origin ?? "cli" })
/** The App Store in the user's own client (phase 1: the only origin that installs). */
const userOp = (token: string, name: string, params: unknown, opts: { key?: string } = {}) => op(token, name, params, { ...opts, origin: "user" })
const read = (token: string, name: string, params: unknown) => call("/v1/read", token, { op: name, params })

const manifest = (id: string, version: string) => ({
  manifestVersion: 1,
  id,
  name: "PRs",
  version,
  description: "Pull requests in the sidebar.",
  publisher: { name: "Acme" },
  engines: { cmux: "^1.0" },
  scopes: { "workspace:read": "Match pull requests to workspaces." },
  optionalScopes: { "notification:post": "Notify on review requests." },
  categories: ["sidebar"]
})
const submit = (token: string, id: string, version: string) =>
  op(token, "app.version.submit", {
    repo: `https://github.com/${id}`,
    tag: `v${version}`,
    manifest: manifest(id, version),
    bundle_url: `https://github.com/${id}/releases/download/v${version}/app.tar.zst`,
    bundle_sha256: "b".repeat(64)
  })

describe("app store over the API (workerd)", { timeout: 60_000 }, () => {
  // The first request in a test file loads the Worker (about 12 s alone, longer under a parallel suite); keep it out of the test budgets.
  beforeAll(async () => {
    await (await worker.fetch("https://api.test/v1/health")).text()
  }, 180_000)

  it("publish, info, install with idempotent replay, list, yank, agent approval, team policy", async () => {
    const tok = await sessionToken(`apps-${crypto.randomUUID()}`)
    expect((await op(tok, "user.ensure", {})).json.ok).toBe(true)
    const app = `acme${crypto.randomUUID().slice(0, 8)}/prs`

    // Publish two versions (ENVIRONMENT=test allows the id claim); reuse is refused.
    const s1 = await submit(tok, app, "1.0.0")
    expect(s1.json).toMatchObject({ ok: true, value: { id: app, tier: "unverified", latest_version: "1.0.0" } })
    expect((await submit(tok, app, "1.1.0")).json.value.latest_version).toBe("1.1.0")
    expect((await submit(tok, app, "1.0.0")).json.error.code).toBe("version.exists")

    const info = await read(tok, "app.info", { app })
    expect(info.status).toBe(200)
    expect(info.json.value.versions.map((v: any) => v.version)).toEqual(["1.1.0", "1.0.0"])
    expect(info.json.value.install_count).toBe(0)
    expect((await read(tok, "app.info", { app: "acme/does-not-exist" })).status).toBe(400)

    // Unverified needs the explicit warning; then install, and the same key replays.
    expect((await userOp(tok, "app.install", { app, scopes: ["workspace:read"] })).json.error.code).toBe("app.unverified")
    const key = crypto.randomUUID()
    const params = { app, version_range: "^1", scopes: ["workspace:read"], accept_unverified: true }
    const first = await userOp(tok, "app.install", params, { key })
    expect(first.json).toMatchObject({ ok: true, value: { status: "installed", install: { version: "1.1.0", scopes_granted: ["workspace:read"] } } })
    const again = await userOp(tok, "app.install", params, { key })
    expect(again.json.replayed).toBe(true)
    expect(again.json.value).toEqual(first.json.value)
    expect((await userOp(tok, "app.install", { ...params, scopes: [] }, { key })).json.error.code).toBe("idempotency.conflict")

    // Phase 1: the CLI and MCP clients cannot install or grow scopes; the App Store (origin user) can.
    for (const origin of ["cli", "mcp"]) {
      const r = await op(tok, "app.install", params, { origin })
      expect(r.json.error).toMatchObject({ code: "app.install.user_only", retryable: false })
      expect(r.json.error.message).toMatch(/App Store/)
      expect((await op(tok, "app.update", { app, accept_scopes: ["notification:post"] }, { origin })).json.error.code).toBe("app.install.user_only")
    }
    const grown = await userOp(tok, "app.update", { app, accept_scopes: ["notification:post"] })
    expect(grown.json.value.install.scopes_granted).toEqual(["notification:post", "workspace:read"])
    const listed = await read(tok, "app.list", {})
    expect(listed.json.value.installs.map((i: any) => i.app)).toEqual([app])
    expect(listed.json.value.approvals).toEqual([])
    expect(listed.json.value.policy).toEqual({ allowed_tiers: null, allowlist: null, blocklist: [] })

    // Yank: an exact install of the yanked version is refused; ranges skip it.
    const y = await op(tok, "app.version.yank", { app, version: "1.1.0", reason: "crashes on start" })
    expect(y.json.value.latest_version).toBe("1.0.0")
    expect((await op(tok, "app.update", { app, version: "1.1.0" })).json.error.code).toBe("app.yanked")
    expect((await userOp(tok, "app.install", { app, version_range: "1.1.0", scopes: ["workspace:read"], accept_unverified: true })).json.error.code).toBe("selector.not_found")

    // Team install in the personal team (unverified needs the tier in the team policy), then the policy blocks it.
    expect((await userOp(tok, "app.install", { app, scope: "team", scopes: ["workspace:read"], accept_unverified: true, version_range: "1.0.0" })).json.error.code).toBe("policy.denied")
    expect((await op(tok, "app.policy.set", { allowed_tiers: ["verified", "unverified"] })).json.ok).toBe(true)
    const t1 = await userOp(tok, "app.install", { app, scope: "team", scopes: ["workspace:read"], accept_unverified: true, version_range: "1.0.0" })
    expect(t1.json).toMatchObject({ ok: true, stream: expect.stringMatching(/^team:/), value: { status: "installed", install: { scope: "team", version: "1.0.0" } } })
    expect((await op(tok, "app.policy.set", { blocklist: [app] })).json.ok).toBe(true)
    expect((await op(tok, "app.remove", { app, scope: "team" })).json.value).toEqual({ app, removed: true })
    expect((await userOp(tok, "app.install", { app, scope: "team", scopes: ["workspace:read"], accept_unverified: true })).json.error.code).toBe("policy.denied")
    const teamList = await read(tok, "app.list", { scope: "team" })
    expect(teamList.json.value.policy.blocklist).toEqual([app])
    expect(teamList.json.value.installs).toEqual([])

    // Another user's team cannot submit versions of this app.
    const other = await sessionToken(`apps-other-${crypto.randomUUID()}`)
    await op(other, "user.ensure", {})
    expect((await submit(other, app, "2.0.0")).json.error.code).toBe("app.not_publisher")
    expect((await op(other, "app.version.yank", { app, version: "1.0.0", reason: "x" })).json.error.code).toBe("app.not_publisher")
  })

  it("ops on one socket commit in order, even when the first awaits the AppDO lookup", async () => {
    const tok = await sessionToken(`apps-${crypto.randomUUID()}`)
    await op(tok, "user.ensure", {})
    const app = `acme${crypto.randomUUID().slice(0, 8)}/ordered`
    await submit(tok, app, "1.0.0")
    const res = await worker.fetch("https://api.test/v1/wire/user", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${tok}` } })
    expect(res.status).toBe(101)
    const ws = res.webSocket!
    const replies = new Map<string, any>()
    let wake: (() => void) | undefined
    ws.addEventListener("message", (e) => {
      const f = JSON.parse(e.data as string)
      if (f.t === "result" || f.t === "reject") replies.set(f.idempotency_key, f)
      wake?.()
    })
    ws.accept()
    const send = (key: string, name: string, params: unknown) => ws.send(JSON.stringify({ t: "op", op: name, params, idempotency_key: key, origin: "user" }))
    send("k-install", "app.install", { app, scopes: ["workspace:read"], accept_unverified: true })
    send("k-grant", "app.grant.set", { app, scopes: ["workspace:read", "notification:post"] })
    while (replies.size < 2) await new Promise<void>((r) => (wake = r))
    expect(replies.get("k-install")).toMatchObject({ t: "result" })
    expect(replies.get("k-grant")).toMatchObject({ t: "result", value: { scopes_granted: ["notification:post", "workspace:read"] } })
    ws.close()
  })

  it("first-party default apps: listed as installed with nothing recorded, hidden, shown, removed", async () => {
    const staff = await sessionToken("apps-staff")
    await op(staff, "user.ensure", {})
    const welcome = "manaflow-ai/welcome"
    const pub = await submit(staff, welcome, "1.0.0")
    expect(pub.json.value.tier).toBe("first-party")
    const tok = await sessionToken(`apps-${crypto.randomUUID()}`)
    await op(tok, "user.ensure", {})
    const listed = async () => ((await read(tok, "app.list", { scope: "user" })).json.value.installs as Array<any>).filter((i) => i.app === welcome)
    expect(await listed()).toMatchObject([{ app: welcome, by_default: true, hidden: false, version: "1.0.0", scopes_granted: ["workspace:read"] }])
    expect((await read(tok, "app.list", {})).json.value).not.toHaveProperty("default_prefs")
    // Hiding grants nothing: any origin (here the CLI) may do it, and it is idempotent.
    expect((await op(tok, "app.hide", { app: welcome })).json.value).toEqual({ app: welcome, hidden: true })
    expect((await op(tok, "app.hide", { app: welcome })).json).toMatchObject({ ok: true, sequence: 0 })
    expect((await listed())[0].hidden).toBe(true)
    expect((await op(tok, "app.unhide", { app: welcome }, { origin: "mcp" })).json.value.hidden).toBe(false)
    expect((await op(tok, "app.remove", { app: welcome })).json.value).toEqual({ app: welcome, removed: true })
    expect(await listed()).toEqual([])
    expect((await op(tok, "app.hide", { app: welcome })).json.error.code).toBe("selector.not_found")
    expect((await op(tok, "app.hide", { app: "acme/never-installed" })).json.error.code).toBe("selector.not_found")
  })

  it("search answers owner.unreachable without the read-only Hyperdrive binding, and validates params", async () => {
    const tok = await sessionToken(`apps-${crypto.randomUUID()}`)
    expect((await read(tok, "app.search", { query: "prs" })).status).toBe(503)
    expect((await read(tok, "app.search", { limit: 500 })).status).toBe(400)
  })

  it("routes AppDO ops by the app the params name, never by a client-sent resolved", async () => {
    const tok = await sessionToken(`apps-${crypto.randomUUID()}`)
    await op(tok, "user.ensure", {})
    expect((await op(tok, "app.version.yank", { version: "1.0.0", reason: "x" })).status).toBe(400)
    // A forged release is replaced by the owner's lookup (here: nothing published).
    const forged = await userOp(tok, "app.install", {
      app: "nobody/nothing",
      scopes: [],
      resolved: { app: "nobody/nothing", version: "1.0.0", tier: "first-party", publisher_team: "team_aaaaaaaaaaaaaaaaaaaa", scopes: [], optional_scopes: [], engines: { cmux: "*" }, bundle_url: "https://evil", bundle_sha256: "c".repeat(64), yanked: false, app_revision: "1" }
    })
    expect(forged.json.error.code).toBe("selector.not_found")
  })
})
