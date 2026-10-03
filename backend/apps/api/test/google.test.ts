import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { gmail, headerValue, messageView, MAX_TEXT_CHARS } from "../src/integrations/gmail.ts"
import { googleApi, googleRefresh, pkceChallenge, pkceVerifier, refuseGoogleScopes, restrictedScopesEnabled } from "../src/integrations/google.ts"
import { googleCalendar } from "../src/integrations/google-calendar.ts"
import type { Http } from "../src/integrations/providers.ts"

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
  return { status: res.status, text: await res.clone().text(), json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const signedIn = async (stackUser: string) => {
  const token = await sessionToken(stackUser)
  const e = await op(token, "user.ensure", {})
  return { token, team: e.json.value.personal_team as string }
}
const fakeHttp = (routes: Record<string, (req: Request) => Promise<Response> | Response>) => {
  const calls: Array<{ url: string; method: string; body: string }> = []
  const http: Http = async (req) => {
    calls.push({ url: req.url, method: req.method, body: await req.clone().text() })
    const key = Object.keys(routes)
      .sort((a, b) => b.length - a.length)
      .find((k) => req.url.startsWith(k))
    return key ? routes[key]!(req) : new Response("not found", { status: 404 })
  }
  return { http, calls }
}
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const b64url = (s: string) => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const fromB64url = (s: string) => {
  const t = s.replace(/-/g, "+").replace(/_/g, "/")
  return new TextDecoder().decode(Uint8Array.from(atob(t + "=".repeat((4 - (t.length % 4)) % 4)), (c) => c.charCodeAt(0)))
}
const G = "https://www.googleapis.com/auth/"
const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
const CAL = "https://www.googleapis.com/calendar/v3"
const e = testEnv as any
const oauth = { kind: "oauth" as const, access_token: "ya29.test", refresh_token: "1//refresh", expires_at: Date.now() + 3600_000 }

describe("Google scopes and tokens", () => {
  it("refuses unknown scopes everywhere and restricted Gmail scopes unless the deployment allows them", () => {
    const refuse = refuseGoogleScopes(["gmail.send", "gmail.readonly", "gmail.modify"])
    const production = { ...e, GOOGLE_RESTRICTED_SCOPES: undefined }
    expect(refuse(production, ["gmail.send"])).toBeUndefined()
    expect(refuse(production, ["gmail.readonly"])).toMatch(/restricted Gmail scope/)
    expect(refuse(production, ["https://mail.google.com/"])).toMatch(/not a scope/)
    expect(refuse(e, ["gmail.readonly", "gmail.modify"])).toBeUndefined()
    expect(typeof gmail.defaultScopes === "function" && gmail.defaultScopes(production)).toEqual(["gmail.send"])
    expect(typeof gmail.defaultScopes === "function" && gmail.defaultScopes(e)).toEqual(["gmail.send", "gmail.modify"])
  })

  it("derives one PKCE verifier per connection attempt (connection and signed state)", async () => {
    const a = await pkceVerifier(e, "conn_aaaaaaaaaaaaaaaaaaaa", "state-1")
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(await pkceVerifier(e, "conn_aaaaaaaaaaaaaaaaaaaa", "state-1")).toBe(a)
    expect(await pkceVerifier(e, "conn_bbbbbbbbbbbbbbbbbbbb", "state-1")).not.toBe(a)
    expect(await pkceVerifier(e, "conn_aaaaaaaaaaaaaaaaaaaa", "state-2")).not.toBe(a)
  })

  it("production honors only a verified restricted-scope setting", () => {
    expect(restrictedScopesEnabled({ ...e, ENVIRONMENT: "production", GOOGLE_RESTRICTED_SCOPES: "testing" })).toBe(false)
    expect(restrictedScopesEnabled({ ...e, ENVIRONMENT: "production", GOOGLE_RESTRICTED_SCOPES: "internal" })).toBe(false)
    expect(restrictedScopesEnabled({ ...e, ENVIRONMENT: "production", GOOGLE_RESTRICTED_SCOPES: "verified" })).toBe(true)
    expect(restrictedScopesEnabled({ ...e, ENVIRONMENT: "staging", GOOGLE_RESTRICTED_SCOPES: "testing" })).toBe(true)
  })

  it("refresh keeps the refresh token; invalid_grant needs reauth; a 503 is retryable", async () => {
    const expired = { ...oauth, expires_at: Date.now() }
    expect(await googleRefresh(e, fakeHttp({}).http, oauth)).toBeUndefined()
    const fresh = await googleRefresh(e, fakeHttp({ "https://oauth2.googleapis.com/token": () => ok({ access_token: "ya29.new", expires_in: 3599 }) }).http, expired)
    expect(fresh).toMatchObject({ kind: "oauth", access_token: "ya29.new", refresh_token: "1//refresh" })
    await expect(googleRefresh(e, fakeHttp({ "https://oauth2.googleapis.com/token": () => ok({ error: "invalid_grant" }, 400) }).http, expired)).rejects.toMatchObject({ code: "needs_reauth" })
    // Our misconfiguration must not send every connection to re-authorization.
    await expect(googleRefresh(e, fakeHttp({ "https://oauth2.googleapis.com/token": () => ok({ error: "invalid_client" }, 401) }).http, expired)).rejects.toMatchObject({ code: "provider.error", retryable: false })
    await expect(googleRefresh(e, fakeHttp({ "https://oauth2.googleapis.com/token": () => ok({}, 503) }).http, expired)).rejects.toMatchObject({ code: "provider.error", retryable: true })
  })

  it("maps Google errors: 401 reauth, 403 rate limit retryable, effect 5xx and network failure indeterminate", async () => {
    const at = (res: () => Response) => fakeHttp({ "https://x.test/": res }).http
    await expect(googleApi(at(() => ok({}, 401)), "t", "GET", "https://x.test/a", { what: "a" })).rejects.toMatchObject({ code: "needs_reauth" })
    await expect(googleApi(at(() => ok({ error: { errors: [{ reason: "userRateLimitExceeded" }] } }, 403)), "t", "GET", "https://x.test/a", { what: "a" })).rejects.toMatchObject({ retryable: true })
    await expect(googleApi(at(() => ok({}, 502)), "t", "POST", "https://x.test/a", { what: "a", effect: true })).rejects.toMatchObject({ code: "mutation.indeterminate" })
    await expect(googleApi(at(() => ok({}, 502)), "t", "GET", "https://x.test/a", { what: "a" })).rejects.toMatchObject({ code: "provider.error", retryable: true })
    const broken: Http = async () => {
      throw new Error("reset")
    }
    await expect(googleApi(broken, "t", "POST", "https://x.test/a", { what: "a", effect: true })).rejects.toMatchObject({ code: "mutation.indeterminate" })
  })
})

describe("Gmail client (fake HTTP)", () => {
  it("returns message text, html flag and attachments at call time, cut at the cap", () => {
    const m = {
      id: "m1",
      threadId: "t1",
      labelIds: ["INBOX", "UNREAD"],
      snippet: "hello",
      internalDate: "1700000000000",
      payload: {
        headers: [
          { name: "From", value: "A <a@example.com>" },
          { name: "Subject", value: "Hi" },
          { name: "X-Other", value: "dropped" }
        ],
        parts: [
          { mimeType: "text/plain", body: { data: b64url("héllo body") } },
          { mimeType: "text/html", body: { data: b64url("<p>x</p>") } },
          { mimeType: "application/pdf", filename: "a.pdf", body: { attachmentId: "att1", size: 10 } },
          { mimeType: "text/plain", filename: "notes.txt", body: { data: b64url("inline attachment") } }
        ]
      }
    }
    expect(messageView(m, true)).toMatchObject({
      id: "m1",
      thread_id: "t1",
      headers: { from: "A <a@example.com>", subject: "Hi" },
      text: "héllo body",
      has_html: true,
      attachments: [{ attachment_id: "att1", filename: "a.pdf", mime_type: "application/pdf", size: 10 }]
    })
    expect((messageView(m, true).headers as Record<string, string>)["x-other"]).toBeUndefined()
    const long = { ...m, payload: { parts: [{ mimeType: "text/plain", body: { data: b64url("x".repeat(MAX_TEXT_CHARS + 10)) } }] } }
    expect(messageView(long, true)).toMatchObject({ text_truncated: true })
    expect((messageView(long, true) as { text: string }).text).toHaveLength(MAX_TEXT_CHARS)
  })

  it("encodes a long non-ASCII subject as folded words of at most 75 characters that decode back", () => {
    const subject = "Grüße aus München ".repeat(20)
    const v = headerValue(subject)
    const words = v.split("\r\n ")
    expect(words.length).toBeGreaterThan(1)
    for (const w of words) expect(w.length).toBeLessThanOrEqual(75)
    const bytes = words.flatMap((w) => [...atob(w.slice("=?UTF-8?B?".length, -2))].map((c) => c.charCodeAt(0)))
    expect(new TextDecoder().decode(Uint8Array.from(bytes))).toBe(subject)
    expect(headerValue("Plain subject")).toBe("Plain subject")
  })

  it("peek reports a deleted thread as missing and keeps the order", async () => {
    const f = fakeHttp({
      [`${GMAIL}/threads/t1`]: () => ok({ messages: [{ snippet: "s", internalDate: "5", labelIds: ["UNREAD"], payload: { headers: [{ name: "Subject", value: "S1" }, { name: "From", value: "f@x.com" }] } }] }),
      [`${GMAIL}/threads/t2`]: () => ok({}, 404)
    })
    const r = await gmail.call(e, f.http, oauth, "mail.threads.peek", { thread_ids: ["t1", "t2"] })
    expect(r.value).toEqual({ threads: [{ thread_id: "t1", subject: "S1", from: "f@x.com", date: 5, snippet: "s", message_count: 1, unread: true, labels: ["UNREAD"] }, { thread_id: "t2", missing: true }] })
  })

  it("modify archives a thread by removing INBOX and needs exactly one target", async () => {
    const f = fakeHttp({ [`${GMAIL}/threads/t1/modify`]: () => ok({ id: "t1" }) })
    expect((await gmail.call(e, f.http, oauth, "mail.modify", { thread_id: "t1", archive: true, remove_labels: ["UNREAD"] })).value).toEqual({ ok: true, added: [], removed: ["UNREAD", "INBOX"] })
    expect(JSON.parse(f.calls[0]!.body)).toEqual({ addLabelIds: [], removeLabelIds: ["UNREAD", "INBOX"] })
    await expect(gmail.call(e, f.http, oauth, "mail.modify", { thread_id: "t1", message_ids: ["m1"], archive: true })).rejects.toThrow(/exactly one/)
    await expect(gmail.call(e, f.http, oauth, "mail.modify", { thread_id: "t1" })).rejects.toThrow(/changes nothing/)
  })
})

describe("Google Calendar client (fake HTTP)", () => {
  it("creates with invitations only when there are attendees and needs one of date and date_time", async () => {
    const f = fakeHttp({ [`${CAL}/calendars/primary/events`]: () => ok({ id: "ev1", htmlLink: "https://calendar.google.com/e" }) })
    const start = { date_time: "2026-10-05T10:00:00-07:00" }
    const end = { date_time: "2026-10-05T10:30:00-07:00" }
    await googleCalendar.call(e, f.http, oauth, "calendar.event.create", { summary: "Solo", start, end })
    expect(f.calls[0]!.url).toContain("sendUpdates=none")
    await googleCalendar.call(e, f.http, oauth, "calendar.event.create", { summary: "Sync", start, end, attendees: ["b@example.com"] })
    expect(f.calls[1]!.url).toContain("sendUpdates=all")
    expect(JSON.parse(f.calls[1]!.body).attendees).toEqual([{ email: "b@example.com" }])
    await expect(googleCalendar.call(e, f.http, oauth, "calendar.event.create", { summary: "Bad", start: {}, end })).rejects.toThrow(/exactly one/)
  })

  it("respond changes only the connected account's attendee row", async () => {
    const attendees = [
      { email: "org@example.com", responseStatus: "accepted", organizer: true },
      { email: "me@example.com", responseStatus: "needsAction", self: true }
    ]
    const f = fakeHttp({ [`${CAL}/calendars/primary/events/ev1`]: (req) => (req.method === "GET" ? ok({ id: "ev1", attendees }) : ok({ id: "ev1" })) })
    await googleCalendar.call(e, f.http, oauth, "calendar.event.respond", { event_id: "ev1", response: "accepted" })
    const patch = f.calls.find((c) => c.method === "PATCH")!
    expect(patch.url).toContain("sendUpdates=all")
    expect(JSON.parse(patch.body).attendees).toEqual([attendees[0], { ...attendees[1], responseStatus: "accepted" }])
    const notInvited = fakeHttp({ [`${CAL}/calendars/primary/events/ev2`]: () => ok({ id: "ev2", attendees: [attendees[0]] }) })
    await expect(googleCalendar.call(e, notInvited.http, oauth, "calendar.event.respond", { event_id: "ev2", response: "declined" })).rejects.toThrow(/not an attendee/)
  })
})

describe("Gmail connection end to end (workerd)", () => {
  it("connects with PKCE, stays private, seals the token, checks granted scopes, and sends once per key", async () => {
    const { token, team } = await signedIn("google-gmail-1")
    expect((await op(token, "integration.connect", { provider: "gmail", sharing: "team" })).json.error.message).toMatch(/always private/)
    expect((await op(token, "integration.connect", { provider: "gmail", scopes: ["https://mail.google.com/"] })).json.error.code).toBe("validation.invalid")

    const connect = await op(token, "integration.connect", { provider: "gmail" })
    expect(connect.json.ok).toBe(true)
    const conn = connect.json.value.connection.id as string
    const url = new URL(connect.json.value.authorize_url)
    expect(url.origin + url.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth")
    expect(url.searchParams.get("scope")).toBe(`openid email ${G}gmail.send ${G}gmail.modify`)
    expect(url.searchParams.get("access_type")).toBe("offline")
    expect(url.searchParams.get("code_challenge_method")).toBe("S256")
    expect(url.searchParams.has("code_verifier")).toBe(false)
    const challenge = url.searchParams.get("code_challenge")!
    const state = url.searchParams.get("state")!

    let sent = 0
    const fake = fakeHttp({
      "https://oauth2.googleapis.com/token": async (req) => {
        const body = new URLSearchParams(await req.text())
        // The verifier sent at exchange is the one whose challenge was in the URL.
        expect(await pkceChallenge(body.get("code_verifier")!)).toBe(challenge)
        // Granular consent: the user allowed send but not modify.
        return ok({ access_token: "ya29.gmail-secret", refresh_token: "1//gmail-refresh-secret", expires_in: 3599, scope: `openid ${G}userinfo.email ${G}gmail.send` })
      },
      "https://openidconnect.googleapis.com/v1/userinfo": () => ok({ sub: "1098", email: "Person@Example.com", email_verified: true }),
      [`${GMAIL}/messages/send`]: async (req) => {
        sent++
        const raw = fromB64url(((await req.json()) as { raw: string }).raw)
        expect(raw).toContain("To: a@example.com, b@example.com\r\n")
        expect(raw).toContain("Subject: =?UTF-8?B?")
        expect(raw).not.toMatch(/\r\nBcc:/)
        return ok({ id: "msg1", threadId: "thr1" })
      }
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state, code: "google-code" })
    expect(done.json).toMatchObject({ ok: true, value: { status: "active", sharing: "private", account: { key: "gmail:1098", name: "person@example.com" }, scopes_granted: ["gmail.send"] } })
    await inDO(connections, async (_i, s) => {
      const dump = JSON.stringify(s.storage.sql.exec("SELECT * FROM credentials").toArray())
      expect(dump).not.toContain("ya29")
      expect(dump).not.toContain("gmail-refresh-secret")
    })

    // Not granted: reads need gmail.readonly or gmail.modify.
    const search = await read(token, "mail.search", { connection: conn, query: "is:unread" })
    expect(search.status).toBe(400)
    expect(search.text).toContain("integration.unavailable")

    // A subject cannot smuggle a header.
    const smuggle = await op(token, "mail.send", { connection: conn, to: ["a@example.com"], subject: "hi\r\nBcc: x@evil.example", body: "x" })
    expect(smuggle.json.ok).toBe(false)
    expect(sent).toBe(0)

    const params = { connection: conn, to: ["a@example.com", "b@example.com"], subject: "Grüße", body: "Hallo\nzweite Zeile" }
    const first = await op(token, "mail.send", params, "send-1")
    expect(first.json).toMatchObject({ ok: true, value: { id: "msg1", thread_id: "thr1" } })
    const again = await op(token, "mail.send", params, "send-1")
    expect(again.json).toMatchObject({ ok: true, replayed: true })
    expect(sent).toBe(1)
  })

  it("keeps only requested scopes (a client cannot add restricted scopes to the URL) and drops restricted ones when the gate closes", async () => {
    const { token, team } = await signedIn("google-gmail-2")
    const connect = await op(token, "integration.connect", { provider: "gmail", scopes: ["gmail.send"] })
    expect(new URL(connect.json.value.authorize_url).searchParams.get("scope")).toBe(`openid email ${G}gmail.send`)
    const state = new URL(connect.json.value.authorize_url).searchParams.get("state")!
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fakeHttp({
        // The user edited the URL and Google granted more than cmux asked for.
        "https://oauth2.googleapis.com/token": () => ok({ access_token: "ya29.x", refresh_token: "1//x", expires_in: 3599, scope: `openid ${G}gmail.send ${G}gmail.readonly ${G}gmail.modify` }),
        "https://openidconnect.googleapis.com/v1/userinfo": () => ok({ sub: "2001", email: "q@example.com", email_verified: true })
      }).http
    })
    const done = await op(token, "integration.complete", { state, code: "c" })
    expect(done.json.value.scopes_granted).toEqual(["gmail.send"])

    // A connection that holds gmail.modify loses read ops when the deployment's gate closes.
    const c2 = await op(token, "integration.connect", { provider: "gmail", scopes: ["gmail.send", "gmail.modify"] })
    const conn2 = c2.json.value.connection.id as string
    await inDO(connections, async (instance) => {
      instance.http = fakeHttp({
        "https://oauth2.googleapis.com/token": () => ok({ access_token: "ya29.y", refresh_token: "1//y", expires_in: 3599, scope: `${G}gmail.send ${G}gmail.modify` }),
        "https://openidconnect.googleapis.com/v1/userinfo": () => ok({ sub: "2002", email: "r@example.com", email_verified: true }),
        [`${GMAIL}/messages?`]: () => ok({ messages: [{ id: "m1", threadId: "t1" }], resultSizeEstimate: 1 })
      }).http
    })
    const done2 = await op(token, "integration.complete", { state: new URL(c2.json.value.authorize_url).searchParams.get("state")!, code: "c2" })
    expect(done2.json.value.scopes_granted).toEqual(["gmail.modify", "gmail.send"])
    expect((await read(token, "mail.search", { connection: conn2, query: "in:inbox" })).json.value).toEqual({ messages: [{ id: "m1", thread_id: "t1" }], result_size_estimate: 1 })
    let saved: unknown
    await inDO(connections, async (instance) => {
      saved = instance.env
      instance.env = { ...instance.env, GOOGLE_RESTRICTED_SCOPES: undefined }
    })
    try {
      expect((await read(token, "mail.search", { connection: conn2, query: "in:inbox" })).text).toContain("integration.unavailable")
    } finally {
      await inDO(connections, async (instance) => {
        instance.env = saved
      })
    }
  })

  it("refuses an account without a verified email and a grant with no requested permission", async () => {
    const { token, team } = await signedIn("google-cal-1")
    const start = async () => {
      const c = await op(token, "integration.connect", { provider: "google_calendar", sharing: "team" })
      return new URL(c.json.value.authorize_url).searchParams.get("state")!
    }
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    const setup = async (scope: string, verified: boolean) =>
      inDO(connections, async (instance) => {
        instance.http = fakeHttp({
          "https://oauth2.googleapis.com/token": () => ok({ access_token: "ya29.c", refresh_token: "1//c", expires_in: 3599, scope }),
          "https://openidconnect.googleapis.com/v1/userinfo": () => ok({ sub: "77", email: "p@example.com", email_verified: verified })
        }).http
      })
    await setup(`openid ${G}calendar.events`, false)
    expect((await op(token, "integration.complete", { state: await start(), code: "c1" })).json.error.code).toBe("integration.state_invalid")
    await setup("openid email", true)
    expect((await op(token, "integration.complete", { state: await start(), code: "c2" })).json.error.message).toMatch(/no requested Google permission/)
    await setup(`openid ${G}calendar.events ${G}calendar.calendarlist.readonly`, true)
    expect((await op(token, "integration.complete", { state: await start(), code: "c3" })).json).toMatchObject({ ok: true, value: { status: "active", sharing: "team", account: { key: "google_calendar:77" } } })
  })
})
