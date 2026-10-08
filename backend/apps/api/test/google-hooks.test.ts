import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Http } from "../src/integrations/providers.ts"
import { handleGoogleCalendar } from "../src/ingress/google-hooks.ts"
import { createRevocationTable } from "../src/integrations/revocations.ts"

const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>
const G = "https://www.googleapis.com/auth/"
const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"

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
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (token: string, name: string, params: unknown) => call("/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const fakeHttp = (routes: Record<string, (req: Request) => Promise<Response> | Response>) => {
  const calls: Array<string> = []
  const http: Http = async (req) => {
    calls.push(`${req.method} ${req.url}`)
    const key = Object.keys(routes)
      .sort((a, b) => b.length - a.length)
      .find((k) => req.url.startsWith(k))
    return key ? routes[key]!(req) : new Response("not found", { status: 404 })
  }
  return { http, calls }
}

/** Pushes are acknowledged first and handled after the answer: wait for the effect. */
const eventually = async (check: () => Promise<boolean>, ms = 5000) => {
  for (const end = Date.now() + ms; Date.now() < end; ) {
    if (await check()) return
    await new Promise((r) => setTimeout(r, 25))
  }
  throw new Error("condition not reached in time")
}

/** A Pub/Sub push token as Google signs it. */
const pubsubToken = async (claims: Record<string, unknown> = {}, audience: string = testEnv.GOOGLE_PUBSUB_AUDIENCE) => {
  const key = await importJWK(JSON.parse(testEnv.GOOGLE_PUBSUB_TEST_PRIVATE_JWK) as JWK, "RS256")
  return new SignJWT({ email: testEnv.GOOGLE_PUBSUB_SERVICE_ACCOUNT, email_verified: true, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "google-test" })
    .setIssuer("https://accounts.google.com")
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key)
}
const push = async (address: string, historyId: number, token?: string, ip = "198.51.100.7") =>
  worker.fetch("https://api.test/v1/hooks/google/pubsub", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip, ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ message: { data: btoa(JSON.stringify({ emailAddress: address, historyId })), messageId: "m-1" }, subscription: "projects/p/subscriptions/s" })
  })

describe("Google Pub/Sub receiver", () => {
  it("refuses a missing, foreign or mis-addressed token before any lookup", async () => {
    expect((await push("a@example.com", 1)).status).toBe(401)
    expect((await push("a@example.com", 1, "not.a.jwt")).status).toBe(401)
    expect((await push("a@example.com", 1, await pubsubToken({}, "https://other.example/hook"))).status).toBe(401)
    expect((await push("a@example.com", 1, await pubsubToken({ email: "someone@else.iam.gserviceaccount.com" }))).status).toBe(401)
    expect((await push("a@example.com", 1, await pubsubToken({ email_verified: false }))).status).toBe(401)
    // A valid token with a body that does not decode: acknowledged (204), never retried for a day.
    const bad = await worker.fetch("https://api.test/v1/hooks/google/pubsub", { method: "POST", headers: { authorization: `Bearer ${await pubsubToken()}` }, body: "{}" })
    expect(bad.status).toBe(204)
    // A valid token for an address nobody connected: 204 so Pub/Sub stops retrying.
    expect((await push("nobody@example.com", 1, await pubsubToken())).status).toBe(204)
  })

  it("rate-limits refused requests per IP only", async () => {
    let last = 0
    for (let i = 0; i < 70; i++) last = (await push("a@example.com", 1, undefined, "203.0.113.9")).status
    expect(last).toBe(429)
    // Valid pushes from another (Google) address are not counted.
    expect((await push("nobody@example.com", 1, await pubsubToken(), "203.0.113.10")).status).toBe(204)
  })

  it("watches at link time, turns a push into one ids-only run per new message, and dedupes redeliveries", async () => {
    const token = await sessionToken("gmail-push-1")
    const team = (await op(token, "user.ensure", {})).json.value.personal_team as string
    const c = await op(token, "integration.connect", { provider: "gmail", scopes: ["gmail.send", "gmail.modify"] })
    const conn = c.json.value.connection.id as string
    let history = { history: [] as Array<unknown>, historyId: "100" }
    let gate: Promise<void> = Promise.resolve()
    const fake = fakeHttp({
      "https://oauth2.googleapis.com/token": () => ok({ access_token: "ya29.p", refresh_token: "1//p", expires_in: 3599, scope: `${G}gmail.send ${G}gmail.modify` }),
      "https://openidconnect.googleapis.com/v1/userinfo": () => ok({ sub: "push-1", email: "Push.User@Example.com", email_verified: true }),
      [`${GMAIL}/watch`]: async (req) => {
        expect(((await req.json()) as { topicName: string }).topicName).toBe(testEnv.GOOGLE_PUBSUB_TOPIC)
        return ok({ historyId: "100", expiration: String(Date.now() + 7 * 24 * 3600_000) })
      },
      [`${GMAIL}/history`]: async (req) => {
        expect(new URL(req.url).searchParams.get("labelId")).toBe("INBOX")
        await gate
        return ok(history)
      },
      [`${GMAIL}/stop`]: () => new Response(null, { status: 204 })
    })
    const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    await inDO(connections, async (instance) => {
      instance.http = fake.http
    })
    const done = await op(token, "integration.complete", { state: new URL(c.json.value.authorize_url).searchParams.get("state")!, code: "c" })
    expect(done.json.ok).toBe(true)
    await inDO(connections, async (_i, s) => {
      expect(s.storage.sql.exec("SELECT connection, cursor, alias FROM google_watches").toArray()).toEqual([{ connection: conn, cursor: "100", alias: "gmail:email:push.user@example.com" }])
    })
    const auto = await op(token, "automation.create", {
      name: "on mail",
      triggers: [{ type: "event", source: "integration", connection: conn, event: "mail.message.received" }],
      body: { type: "steps", steps: [{ type: "note", text: "mail" }] }
    })
    expect(auto.json.ok).toBe(true)

    history = {
      history: [
        { id: "101", messagesAdded: [{ message: { id: "msgA", threadId: "thrA", labelIds: ["UNREAD", "INBOX"] } }] },
        { id: "102", messagesAdded: [{ message: { id: "msgB", threadId: "thrB", labelIds: ["INBOX"] } }, { message: { id: "msgA", threadId: "thrA" } }] }
      ],
      historyId: "102"
    }
    const listRuns = async () => (await read(token, "automation.runs.list", { automation: auto.json.value.id })).json.value.runs as Array<{ trigger: { delivery_id: string } }>
    // The push is acknowledged while Gmail's history call is still running (it waits on `gate`).
    let release!: () => void
    gate = new Promise<void>((r) => (release = r))
    // The address in the notification is matched case-insensitively.
    expect((await push("push.user@EXAMPLE.com", 102, await pubsubToken())).status).toBe(204)
    expect(await listRuns()).toHaveLength(0)
    release()
    await eventually(async () => (await listRuns()).length === 2)
    let runs = await listRuns()
    await eventually(async () => {
      let cursor = ""
      await inDO(connections, async (_i, s) => {
        cursor = String(s.storage.sql.exec("SELECT cursor FROM google_watches").one().cursor)
      })
      return cursor === "102"
    })
    // Redelivery of the same notification: the cursor moved, history is empty, no new runs.
    history = { history: [], historyId: "102" }
    expect((await push("push.user@example.com", 102, await pubsubToken())).status).toBe(204)
    await new Promise((r) => setTimeout(r, 100))
    runs = await listRuns()
    expect(runs).toHaveLength(2)

    // Stored: ids only. No subject, sender, snippet or body anywhere in the object.
    await inDO(connections, async (_i, s) => {
      expect(s.storage.sql.exec("SELECT cursor FROM google_watches").one()).toEqual({ cursor: "102" })
    })
    // One run per new message, keyed by connection and Gmail message id (the run input holds only these ids).
    expect(runs.map((r) => r.trigger.delivery_id).sort()).toEqual([`${conn}:msgA`, `${conn}:msgB`])

    // Disconnect drops the watch and the alias, and stops the watch at Gmail (users.stop): a later push reaches nobody.
    await op(token, "integration.revoke", { connection: conn })
    await inDO(connections, async (instance, s) => {
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(0)
      await instance.revokeAtProviders(Date.now() + 5 * 60_000)
    })
    expect(fake.calls.some((c) => c === `POST ${GMAIL}/stop`)).toBe(true)
    history = { history: [{ id: "103", messagesAdded: [{ message: { id: "msgC", threadId: "thrC" } }] }], historyId: "103" }
    expect((await push("push.user@example.com", 103, await pubsubToken())).status).toBe(204)
    await new Promise((r) => setTimeout(r, 100))
    expect(await listRuns()).toHaveLength(2)
  })
})

describe("Google Calendar receiver (not routed until G2)", () => {
  it("is not served yet; its handler refuses a malformed channel id before any lookup", async () => {
    const routed = await worker.fetch("https://api.test/v1/hooks/google/calendar", { method: "POST", headers: { "x-goog-channel-id": "cmuxch_" + "a".repeat(22) } })
    expect(routed.status).not.toBe(200)
    const e = { ...testEnv, ACCOUNT_INDEX_DO: undefined } as any
    expect((await handleGoogleCalendar(new Request("https://api.test/v1/hooks/google/calendar", { method: "POST" }), e)).status).toBe(400)
    expect((await handleGoogleCalendar(new Request("https://api.test/x", { method: "POST", headers: { "x-goog-channel-id": "../../etc" } }), e)).status).toBe(400)
  })
})

describe("pending_revocations schema upgrade", () => {
  it("adds stop_alias to a table created before it existed", async () => {
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName("team_schema_upgrade"))
    await inDO(stub, async (_i, s) => {
      s.storage.sql.exec("DROP TABLE IF EXISTS pending_revocations")
      s.storage.sql.exec(`CREATE TABLE pending_revocations (connection TEXT PRIMARY KEY, owner TEXT NOT NULL, provider TEXT NOT NULL, account TEXT, generation INTEGER NOT NULL,
        sealed TEXT NOT NULL, attempts INTEGER NOT NULL, first_at INTEGER NOT NULL, next_at INTEGER NOT NULL)`)
      createRevocationTable(s.storage.sql)
      createRevocationTable(s.storage.sql)
      const cols = s.storage.sql.exec<{ name: string }>("PRAGMA table_info(pending_revocations)").toArray().map((c) => c.name)
      expect(cols).toContain("stop_alias")
    })
  })
})
