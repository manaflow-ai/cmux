// GitHub webhooks to a person's live clients (integrations/github-push.ts): the invalidation a
// delivery carries, constant cost per burst, and end to end over workerd: a verified check_run
// webhook reaches the watching feed socket as `integration.changed`, and nothing else does.
import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { githubChangeOf, GithubPushCoalescer, MAX_CHANGES_PER_FRAME, type IntegrationChangedFrame } from "../src/integrations/github-push.ts"

const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any) => Promise<void>) => Promise<void>

const ev = (event: string, payload: unknown) => ({ provider: "github" as const, account: "github:installation:99", delivery_id: crypto.randomUUID(), event, payload })

describe("githubChangeOf: what a delivery tells a pull request list", () => {
  it("names the repo, the pull request when the payload has one, and the kind", () => {
    expect(githubChangeOf(ev("check_run.completed", { repository: { full_name: "Acme/Web" }, check_run: { pull_requests: [{ number: 7 }] } }))).toEqual({ repo: "acme/web", number: 7, kind: "check_run" })
    expect(githubChangeOf(ev("check_suite.completed", { repository: { full_name: "acme/web" }, check_suite: { pull_requests: [] } }))).toEqual({ repo: "acme/web", kind: "check_suite" })
    expect(githubChangeOf(ev("pull_request.synchronize", { repository: { full_name: "acme/web" }, number: 3, pull_request: { number: 3 } }))).toEqual({ repo: "acme/web", number: 3, kind: "pull_request" })
    expect(githubChangeOf(ev("pull_request_review.submitted", { repository: { full_name: "acme/web" }, pull_request: { number: 4 } }))).toEqual({ repo: "acme/web", number: 4, kind: "pull_request_review" })
    expect(githubChangeOf(ev("status", { repository: { full_name: "acme/web" }, sha: "abc" }))).toEqual({ repo: "acme/web", kind: "status" })
  })

  it("ignores events a pull request list does not show, and malformed repos", () => {
    expect(githubChangeOf(ev("push", { repository: { full_name: "acme/web" } }))).toBeNull()
    expect(githubChangeOf(ev("issues.opened", { repository: { full_name: "acme/web" } }))).toBeNull()
    expect(githubChangeOf(ev("check_run.completed", { repository: { full_name: "../etc" } }))).toBeNull()
    expect(githubChangeOf({ ...ev("check_run.completed", { repository: { full_name: "acme/web" } }), provider: "slack" as any })).toBeNull()
  })
})

describe("GithubPushCoalescer: constant cost per burst", () => {
  const harness = () => {
    let now = 1_000
    const timers: Array<{ at: number; fn: () => void }> = []
    const sent: Array<{ user: string; frame: IntegrationChangedFrame }> = []
    const c = new GithubPushCoalescer({
      send: (user, frame) => sent.push({ user, frame }),
      now: () => now,
      setTimer: (fn, ms) => (timers.push({ at: now + ms, fn }), 0 as unknown as ReturnType<typeof setTimeout>),
      windowMs: 1_000
    })
    const advance = (ms: number) => {
      now += ms
      for (const t of timers.splice(0).sort((a, b) => a.at - b.at)) (t.at <= now ? t.fn() : timers.push(t))
    }
    return { c, sent, advance, timers }
  }

  it("the first change goes at once; a burst of 500 in the window is one more frame, deduped and capped", () => {
    const h = harness()
    h.c.add("u1", { repo: "acme/web", number: 1, kind: "check_run" })
    expect(h.sent).toHaveLength(1)
    for (let i = 0; i < 500; i++) h.c.add("u1", { repo: "acme/web", number: i % 80, kind: "check_run" })
    expect(h.sent).toHaveLength(1)
    h.advance(1_000)
    expect(h.sent).toHaveLength(2)
    expect(h.sent[1]!.frame.changes).toHaveLength(MAX_CHANGES_PER_FRAME)
    expect(h.sent[1]!.frame.more).toBe(true)
    // The window ends with nothing new: no frame, and the entry is gone (no timer left).
    h.advance(1_000)
    expect(h.sent).toHaveLength(2)
    expect(h.timers).toHaveLength(0)
    // Quiet again: the next change goes at once.
    h.c.add("u1", { repo: "acme/web", kind: "status" })
    expect(h.sent).toHaveLength(3)
  })

  it("listeners are independent", () => {
    const h = harness()
    h.c.add("u1", { repo: "acme/web", kind: "status" })
    h.c.add("u2", { repo: "acme/web", kind: "status" })
    expect(h.sent.map((s) => s.user)).toEqual(["u1", "u2"])
  })
})

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
const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** A signed-in user with one registered Mac install and its access token (as feed.test.ts). */
const setup = async (stackUser: string) => {
  const session = await sessionToken(stackUser)
  const ensured = (await op(session, "user.ensure", {})).json.value
  const user = ensured.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })
  const install = reg.json.value.id as string
  const ch = await call("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
  return { session, user, team: ensured.personal_team as string, token: tok.json.access_token as string }
}

const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
/** Links a private GitHub App connection (installation 99, repos acme/web and acme/api), as chief-jobs-upstash.test.ts does. */
const linkGitHub = async (token: string, team: string) => {
  const connect = await op(token, "integration.connect", { provider: "github", sharing: "private" })
  const state = new URL(connect.json.value.authorize_url).searchParams.get("state")!
  const routes: Record<string, () => Response> = {
    "https://github.com/login/oauth/access_token": () => ok({ access_token: "ghu_user" }),
    "https://api.github.com/user/installations/99/repositories": () => ok({ repositories: [{ full_name: "acme/web" }, { full_name: "acme/api" }] }),
    "https://api.github.com/user/installations": () => ok({ installations: [{ id: 99, account: { login: "acme", type: "Organization" }, permissions: { checks: "read", pull_requests: "read" } }] }),
    "https://api.github.com/app/installations/99/access_tokens": () => ok({ token: "ghs_x", expires_at: new Date(Date.now() + 3600_000).toISOString() }, 201)
  }
  await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (i) => {
    i.http = async (req: Request) => {
      const key = Object.keys(routes).find((k) => req.url.startsWith(k))
      return key ? routes[key]!() : new Response("not found", { status: 404 })
    }
  })
  const done = await op(token, "integration.complete", { state, code: "c", installation_id: "99", setup_action: "install" })
  expect(done.json.value?.status, JSON.stringify(done.json)).toBe("active")
}

const hmac = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
/** A GitHub App webhook delivery as GitHub sends it to /v1/hooks/github. */
const ghHook = async (event: string, payload: Record<string, unknown>) => {
  const body = JSON.stringify({ installation: { id: 99 }, ...payload })
  const res = await worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmac(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": crypto.randomUUID(), "x-github-event": event }, body })
  expect(res.status).toBe(200)
}

const openFeed = async (token: string) => {
  const res = await worker.fetch("https://api.test/v1/wire/feed", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  const waiters: Array<() => void> = []
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    waiters.splice(0).forEach((w) => w())
  })
  ws.accept()
  const until = async (pred: (fs: Array<any>) => boolean) => {
    while (!pred(frames)) await new Promise<void>((r) => waiters.push(r))
  }
  return { ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}
const changed = (frames: Array<any>) => frames.filter((f) => f.t === "integration.changed")

describe("GitHub webhooks reach the watching feed socket (workerd)", { timeout: 60_000 }, () => {
  it("a check_run webhook becomes one integration.changed frame on the watching socket; out-of-scope repos and unwatched sockets hear nothing", async () => {
    const s = await setup("gh-push-1")
    await linkGitHub(s.session, s.team)
    const wire = await openFeed(s.token)
    wire.send({ t: "subscribe", stream: `feed:${s.user}`, pending: [] })
    await wire.until((fs) => fs.some((f) => f.t === "snapshot"))
    // A second socket of the same person that never asks hears nothing.
    const quiet = await openFeed(s.token)
    quiet.send({ t: "subscribe", stream: `feed:${s.user}`, pending: [] })
    await quiet.until((fs) => fs.some((f) => f.t === "snapshot"))

    wire.send({ t: "integration.watch", provider: "github" })
    await wire.until((fs) => fs.some((f) => f.t === "integration.watching"))
    expect(wire.frames.find((f) => f.t === "integration.watching")).toEqual({ t: "integration.watching", provider: "github", live: true })

    await ghHook("check_run", { action: "completed", repository: { full_name: "acme/web" }, check_run: { id: 1, conclusion: "failure", pull_requests: [{ number: 7 }] } })
    await wire.until((fs) => changed(fs).length >= 1)
    expect(changed(wire.frames)[0]).toEqual({ t: "integration.changed", provider: "github", changes: [{ repo: "acme/web", number: 7, kind: "check_run" }] })
    // The payload never travels: no conclusion, title or output.
    expect(JSON.stringify(changed(wire.frames))).not.toContain("failure")

    // A repo the connection does not cover, and an event a pull request list does not show: nothing.
    await ghHook("check_run", { action: "completed", repository: { full_name: "other/repo" }, check_run: { pull_requests: [{ number: 1 }] } })
    await ghHook("push", { repository: { full_name: "acme/web" }, after: "abc" })
    // A burst inside the window: at most one more frame, carrying every distinct change.
    for (let i = 0; i < 5; i++) await ghHook("check_suite", { action: "completed", repository: { full_name: "acme/api" }, check_suite: { pull_requests: [{ number: 10 + i }] } })
    await wire.until((fs) => changed(fs).length >= 2 && changed(fs).flatMap((f) => f.changes).length >= 6)
    await new Promise((r) => setTimeout(r, 2_000))
    const frames = changed(wire.frames)
    expect(frames.length).toBeLessThanOrEqual(3)
    const all = frames.flatMap((f) => f.changes)
    expect(all.map((c: any) => c.repo).sort()).toEqual(["acme/api", "acme/api", "acme/api", "acme/api", "acme/api", "acme/web"])
    expect(changed(quiet.frames)).toHaveLength(0)
    quiet.ws.close()
    wire.ws.close()
  })

  it("a person with no GitHub connection is told the push is not live", async () => {
    const s = await setup("gh-push-none")
    const wire = await openFeed(s.token)
    wire.send({ t: "subscribe", stream: `feed:${s.user}`, pending: [] })
    await wire.until((fs) => fs.some((f) => f.t === "snapshot"))
    wire.send({ t: "integration.watch", provider: "github" })
    await wire.until((fs) => fs.some((f) => f.t === "integration.watching"))
    expect(wire.frames.find((f) => f.t === "integration.watching")).toEqual({ t: "integration.watching", provider: "github", live: false })
    wire.send({ t: "integration.watch", provider: "slack" })
    await wire.until((fs) => fs.some((f) => f.t === "error"))
    wire.ws.close()
  })
})
