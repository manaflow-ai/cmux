import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, exportPKCS8, generateKeyPair, decodeJwt, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"

/**
 * GitHub sign-in per Chief (plans/cmux-next/chief-github-DESIGN.md, chief-brain-cc/github.ts): the device flow
 * started from a turn machine (`chief-github login`) is polled by the Chief's `<agent>/github` object after the
 * turn, the token is sealed there and given to every later turn machine instead of the Worker's shared secret;
 * a pasted token, a GitHub App installation, sign-out, the owner's settings route, and nothing of it reaches
 * replies, runs, another Chief or a deployment without INTEGRATIONS_KEK. GitHub is faked at its HTTP boundary.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; CHIEF_BRAIN_DO: DurableObjectNamespace }
const testEnv = env as unknown as TestEnv
const worker = (exports as unknown as { default: Fetcher }).default
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, text: await res.clone().text(), json: (await res.json().catch(() => null)) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>

const SETTINGS = { CHIEF_CC_ENABLED: "1", CHIEF_CC_SNAPSHOT: "sh-test-chief-cc", CHIEF_CC_FREESTYLE_API_KEY: "test-freestyle-key-not-real", CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test", CHIEF_CC_TS_OAUTH: JSON.stringify({ client_id: "test-client", client_secret: "test-client-secret-not-real" }), CHIEF_CC_GITHUB_TOKEN: "shared-worker-token-not-real" }
const saved: Record<string, string | undefined> = {}
beforeAll(() => {
  for (const k of [...Object.keys(SETTINGS), "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_CC_OWNERS"]) saved[k] = testEnv[k]
  Object.assign(testEnv, SETTINGS)
})
afterAll(() => {
  for (const [k, v] of Object.entries(saved)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
})
afterEach(() => vi.restoreAllMocks())

const enabledChief = async (sub: string) => {
  const token = await sessionToken(sub)
  const user = (await op(token, "user.ensure", {})).value.id as string
  testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const chief = (await op(token, "chief.create", { display_name: "GitHub Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, { enabled: true, model: "claude-opus-5-5" })
  }
  expect(on.status, on.text).toBe(200)
  return { token, chief }
}
const replies = async (token: string, conversation: string, chief: string, n: number) => {
  for (let i = 0; i < 300; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no ${n} chief replies`)
}
const send = (token: string, conversation: string, key: string, text: string) => op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)
const call = async (s: Started, vm: unknown) => {
  const r = await notes(s, { run: s.run, vm })
  return { status: r.status, body: (await r.json().catch(() => null)) as any }
}
const githubObject = (agent: string) => testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/github`))

/** github.com and api.github.com: the device flow, /user, and an App's installation tokens. */
const fakeGitHub = () => {
  const inner = vi.mocked(globalThis.fetch).getMockImplementation()!
  const gh = { polls: 0, approved: false, expiresIn: 900, devices: [] as Array<string>, devicePosts: [] as Array<string>, minted: 0, jwts: [] as Array<string>, users: new Map<string, { login: string; scopes: string; expires?: string }>() }
  gh.users.set("gho_device_token_not_real", { login: "octo", scopes: "gist, read:org, repo, workflow" })
  gh.users.set("github_pat_good_not_real", { login: "octo-pat", scopes: "", expires: "2026-12-01 00:00:00 UTC" })
  vi.mocked(globalThis.fetch).mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin === "https://github.com" && url.pathname === "/login/device/code") {
      gh.devicePosts.push(await req.text())
      const n = gh.devicePosts.length
      gh.devices.push(n === 1 ? "device-code-secret-not-real" : `device-code-secret-${n}-not-real`)
      return Response.json({ device_code: gh.devices.at(-1), user_code: n === 1 ? "ABCD-1234" : `EFGH-000${n}`, verification_uri: "https://github.com/login/device", expires_in: gh.expiresIn, interval: 0 })
    }
    if (url.origin === "https://github.com" && url.pathname === "/login/oauth/access_token") {
      const body = new URLSearchParams(await req.text())
      expect(body.get("device_code")).toBe(gh.devices.at(-1))
      expect(body.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:device_code")
      gh.polls++
      if (!gh.approved) return Response.json({ error: "authorization_pending" })
      return Response.json({ access_token: "gho_device_token_not_real", token_type: "bearer", scope: "gist,read:org,repo,workflow" })
    }
    if (url.origin === "https://api.github.com" && url.pathname === "/user") {
      const u = gh.users.get((req.headers.get("authorization") ?? "").replace(/^(Bearer|token) /, ""))
      if (!u) return Response.json({ message: "Bad credentials" }, { status: 401 })
      return Response.json({ login: u.login, id: 1 }, { headers: { "x-oauth-scopes": u.scopes, ...(u.expires ? { "github-authentication-token-expiration": u.expires } : {}) } })
    }
    if (url.origin === "https://api.github.com" && url.pathname === "/app") {
      gh.jwts.push((req.headers.get("authorization") ?? "").replace(/^Bearer /, ""))
      return Response.json({ slug: "lawrence-chief-bot", name: "Lawrence Chief" })
    }
    const inst = /^\/app\/installations\/(\d+)\/access_tokens$/.exec(url.pathname)
    if (url.origin === "https://api.github.com" && inst && req.method === "POST") {
      gh.jwts.push((req.headers.get("authorization") ?? "").replace(/^Bearer /, ""))
      gh.minted++
      // The first token is nearly stale: the next turn mints another.
      const expires = new Date(Date.now() + (gh.minted === 1 ? 2 * 60_000 : 60 * 60_000)).toISOString()
      return Response.json({ token: `ghs_installation_${gh.minted}_not_real`, expires_at: expires, permissions: { contents: "write", pull_requests: "write" } }, { status: 201 })
    }
    return inner(input, init)
  })
  return gh
}

describe("GitHub sign-in per Chief", { timeout: 120_000 }, () => {
  it("runs the device flow past the turn, seals the token per Chief and gives it to the next turn machines, never to replies or another Chief", async () => {
    const seen: Record<string, any> = {}
    const ids: Record<string, string> = {}
    const cloud = fakeCloud(
      () => "ok",
      async (s, n) => {
        if (!s.input.notes_url.includes(ids.a ?? "-")) return
        if (n === 1) {
          seen.before = await call(s, { action: "github_status" })
          seen.login = await call(s, { action: "github_login" })
          seen.wait = await call(s, { action: "github_wait" })
        }
      }
    )
    const gh = fakeGitHub()
    const a = await enabledChief("chief-github-a")
    ids.a = a.chief.id
    const b = await enabledChief("chief-github-b")
    expect((await send(a.token, a.chief.main_conversation, "g1", "sign in to github")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    const first = cloud.started[0]!
    // Not signed in yet: the shared secret still goes, and the Chief is told to offer sign-in.
    expect((first.input as any).github_token).toBe("shared-worker-token-not-real")
    expect(first.input.system).toContain("chief-github login")
    expect(seen.before.body).toMatchObject({ signed_in: false })
    expect(seen.login.status).toBe(200)
    expect(seen.login.body).toMatchObject({ pending: { user_code: "ABCD-1234", verification_uri: "https://github.com/login/device" } })
    // The card the Chief posts: the code and the page as a Markdown link on its own line.
    expect(seen.login.body.card).toContain("`ABCD-1234`")
    expect(seen.login.body.card).toContain("\n[github.com/login/device](https://github.com/login/device)")
    expect(new URLSearchParams(gh.devicePosts[0]!).get("scope")).toBe("repo read:org gist workflow")
    expect(seen.wait.body).toMatchObject({ signed_in: false, pending: { user_code: "ABCD-1234" } })

    // The turn is over; the Chief's own object keeps polling (its job) until the person approves.
    expect(gh.polls).toBeGreaterThan(0)
    gh.approved = true
    let status: any = null
    for (let i = 0; i < 40; i++) {
      await fireAlarm(githubObject(a.chief.id))
      status = (await http("GET", `/v1/chiefs/${a.chief.id}/github`, a.token)).json
      if (status?.value?.signed_in) break
      await new Promise((r) => setTimeout(r, 50))
    }
    expect(status.value).toMatchObject({ signed_in: true, kind: "device", login: "octo", scopes: ["gist", "read:org", "repo", "workflow"], expires_at: null })
    expect(status.value.pending).toBeUndefined()
    expect(JSON.stringify(status)).not.toContain("gho_device_token_not_real")

    // The next turn machine gets the Chief's own token and the signed-in line.
    expect((await send(a.token, a.chief.main_conversation, "g2", "push it")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
    const second = cloud.started.at(-1)!
    expect((second.input as any).github_token).toBe("gho_device_token_not_real")
    expect(second.input.system).toContain("signed in as octo")

    // Another Chief gets none of it.
    expect((await send(b.token, b.chief.main_conversation, "g3", "hello")).ok).toBe(true)
    await replies(b.token, b.chief.main_conversation, b.chief.id, 1)
    expect((cloud.started.at(-1)!.input as any).github_token).toBe("shared-worker-token-not-real")
    expect((await http("GET", `/v1/chiefs/${a.chief.id}/github`, b.token)).status).toBe(403)

    // Never in history, runs, or the object's storage in clear.
    const runs = (await http("GET", `/v1/chiefs/${a.chief.id}/runs?conversation=${a.chief.main_conversation}`, a.token)).json
    expect(JSON.stringify([await history(a.token, a.chief.main_conversation), runs])).not.toContain("gho_device_token_not_real")
    const stored = await (githubObject(a.chief.id) as any).ccGithubDump()
    expect(JSON.stringify(stored)).not.toContain("gho_device_token_not_real")
    expect(JSON.stringify(stored)).not.toContain("device-code-secret")
  })

  it("takes a pasted token after checking it, shows its expiry, signs out, and mints GitHub App installation tokens fresh", async () => {
    fakeCloud(() => "ok")
    const gh = fakeGitHub()
    const a = await enabledChief("chief-github-pat")
    const path = `/v1/chiefs/${a.chief.id}/github`
    expect((await http("POST", path, a.token, { action: "pat", token: "github_pat_bad_not_real" })).status).toBe(400)
    const pat = await http("POST", path, a.token, { action: "pat", token: "github_pat_good_not_real" })
    expect(pat.status, pat.text).toBe(200)
    expect(pat.json.value).toMatchObject({ signed_in: true, kind: "pat", login: "octo-pat", scopes: [], expires_at: Date.parse("2026-12-01T00:00:00Z") })
    expect(pat.text).not.toContain("github_pat_good_not_real")
    expect(await (githubObject(a.chief.id) as any).ccGithubTurn(a.chief.id)).toMatchObject({ token: "github_pat_good_not_real" })

    const out = await http("POST", path, a.token, { action: "logout" })
    expect(out.json.value).toMatchObject({ signed_in: false })
    expect(out.json.value.note).toContain("https://github.com/settings")
    expect((await (githubObject(a.chief.id) as any).ccGithubTurn(a.chief.id)).token).toBeNull()

    const { privateKey } = await generateKeyPair("RS256", { extractable: true })
    const pem = await exportPKCS8(privateKey)
    const app = await http("POST", path, a.token, { action: "app", app_id: "123456", installation_id: "987", private_key: pem })
    expect(app.status, app.text).toBe(200)
    expect(app.json.value).toMatchObject({ signed_in: true, kind: "app", login: "lawrence-chief-bot[bot]", scopes: ["contents:write", "pull_requests:write"] })
    expect(app.text).not.toContain("PRIVATE KEY")
    expect(decodeJwt(gh.jwts[0]!)).toMatchObject({ iss: "123456" })
    const t1 = await (githubObject(a.chief.id) as any).ccGithubTurn(a.chief.id)
    // The first one had under 10 minutes left: the turn got a new one.
    expect(t1.token).toBe("ghs_installation_2_not_real")
    const t2 = await (githubObject(a.chief.id) as any).ccGithubTurn(a.chief.id)
    expect(t2.token).toBe("ghs_installation_2_not_real")
    expect(gh.minted).toBe(2)
  })

  it("refuses to keep a token on a deployment with no INTEGRATIONS_KEK", async () => {
    fakeCloud(() => "ok")
    fakeGitHub()
    const a = await enabledChief("chief-github-nokek")
    const kek = testEnv.INTEGRATIONS_KEK
    delete testEnv.INTEGRATIONS_KEK
    try {
      const r = await http("POST", `/v1/chiefs/${a.chief.id}/github`, a.token, { action: "pat", token: "github_pat_good_not_real" })
      expect(r.status).toBe(503)
      expect(r.text).toContain("INTEGRATIONS_KEK")
    } finally {
      testEnv.INTEGRATIONS_KEK = kek
    }
  })

  it("keeps a fresh device code ready: a new one when the old expires, until approved", async () => {
    const seen: Record<string, any> = {}
    fakeCloud(
      () => "ok",
      async (s, n) => {
        if (n === 1) seen.login = await call(s, { action: "github_login" })
      }
    )
    const gh = fakeGitHub()
    gh.expiresIn = 1
    const a = await enabledChief("chief-github-renew")
    expect((await send(a.token, a.chief.main_conversation, "r1", "sign in to github")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    expect(seen.login.body.pending.user_code).toBe("ABCD-1234")
    // The card says when the code ends, so the Chief can wake itself then (chief-wake).
    expect(seen.login.body.wake_in).toBeGreaterThan(0)
    gh.expiresIn = 900
    await new Promise((r) => setTimeout(r, 1200))
    // The expired code is replaced at once when the status is read: the woken Chief posts the new one.
    const status = (await http("GET", `/v1/chiefs/${a.chief.id}/github`, a.token)).json.value
    expect(status).toMatchObject({ signed_in: false, pending: { user_code: "EFGH-0002" } })
    expect(status.pending.renewals).toBe(1)
    gh.approved = true
    let s: any = null
    for (let i = 0; i < 40 && !s?.signed_in; i++) {
      await fireAlarm(githubObject(a.chief.id))
      s = (await http("GET", `/v1/chiefs/${a.chief.id}/github`, a.token)).json.value
    }
    expect(s).toMatchObject({ signed_in: true, login: "octo" })
  })

  it("lets a Cloud Chief set a timer that wakes it with a [wake] message, list it and clear it", async () => {
    const seen: Record<string, any> = {}
    const before = testEnv.CHIEF_CC_WAKE_MIN_SECONDS
    testEnv.CHIEF_CC_WAKE_MIN_SECONDS = "0"
    try {
      const cloud = fakeCloud(
        () => "ok",
        async (s, n) => {
          if (n !== 1) return
          seen.bad = await call(s, { action: "wake_set", seconds: -5, note: "x" })
          seen.later = await call(s, { action: "wake_set", seconds: 3600, note: "not this one" })
          seen.list = await call(s, { action: "wake_list" })
          seen.clear = await call(s, { action: "wake_clear" })
          seen.set = await call(s, { action: "wake_set", seconds: 0, note: "post the new GitHub code" })
        }
      )
      const a = await enabledChief("chief-github-wake")
      expect((await send(a.token, a.chief.main_conversation, "w1", "sign in to github")).ok).toBe(true)
      await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
      expect(seen.bad.status).toBe(400)
      expect(seen.later.status).toBe(200)
      expect(seen.list.body.wakes.map((w: any) => w.note)).toEqual(["not this one"])
      expect(seen.clear.body).toMatchObject({ cleared: 1 })
      expect(seen.set.status).toBe(200)
      const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${a.chief.id}/${a.chief.main_conversation}`))
      for (let i = 0; i < 40 && cloud.started.length < 2; i++) {
        await fireAlarm(brain)
        await new Promise((r) => setTimeout(r, 50))
      }
      // A second turn with no message from anyone: the timer's note starts it.
      expect(cloud.started.length).toBe(2)
      expect(cloud.started[1]!.input.prompt).toContain("[wake] post the new GitHub code")
      expect(cloud.started[1]!.input.prompt).not.toContain("not this one")
      await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
      // The timer client ships to every turn machine.
      expect((cloud.started[1]!.input as any).files[".local/bin/chief-wake"]).toContain("wake_set")
    } finally {
      before === undefined ? delete testEnv.CHIEF_CC_WAKE_MIN_SECONDS : (testEnv.CHIEF_CC_WAKE_MIN_SECONDS = before)
    }
  })
})
