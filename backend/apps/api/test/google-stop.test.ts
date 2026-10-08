import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { LINK_DEAD_AFTER } from "../src/ingress/google-hooks.ts"
import { ensureGmailWatch, runWatchWork } from "../src/integrations/google-watches.ts"
import { createWatchTable } from "../src/integrations/gmail-push.ts"
import { upgradeLinks } from "../src/account-index-do.ts"
import { STOP_BEFORE_REVOKE_MS } from "../src/integrations/revocations.ts"
import type { Http } from "../src/integrations/providers.ts"

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
const op = async (token: string, name: string, params: unknown) => {
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" }) })
  return (await res.json()) as any
}
const ok = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const pubsubToken = async (issuedAt?: number) => {
  const key = await importJWK(JSON.parse(testEnv.GOOGLE_PUBSUB_TEST_PRIVATE_JWK) as JWK, "RS256")
  return new SignJWT({ email: testEnv.GOOGLE_PUBSUB_SERVICE_ACCOUNT, email_verified: true })
    .setProtectedHeader({ alg: "RS256", kid: "google-test" })
    .setIssuer("https://accounts.google.com")
    .setAudience(testEnv.GOOGLE_PUBSUB_AUDIENCE)
    .setIssuedAt(issuedAt)
    .setExpirationTime(Math.floor(Date.now() / 1000) + 300)
    .sign(key)
}
const push = async (address: string) =>
  worker.fetch("https://api.test/v1/hooks/google/pubsub", {
    method: "POST",
    headers: { authorization: `Bearer ${await pubsubToken()}` },
    body: JSON.stringify({ message: { data: btoa(JSON.stringify({ emailAddress: address, historyId: 5 })), messageId: "m" } })
  })

/** Links a Gmail connection whose watch starts at once; `stop` answers users.stop. */
const linkGmail = async (user: string, stop: () => number, opts: { email?: string; history?: () => Response } = {}) => {
  const token = await sessionToken(user)
  const team = (await op(token, "user.ensure", {})).value.personal_team as string
  const c = await op(token, "integration.connect", { provider: "gmail", scopes: ["gmail.send", "gmail.modify"] })
  const conn = c.value.connection.id as string
  const calls: Array<string> = []
  const http: Http = async (req) => {
    calls.push(`${req.method} ${req.url.split("?")[0]}`)
    if (req.url.startsWith("https://oauth2.googleapis.com/token")) return ok({ access_token: "ya29.s", refresh_token: "1//s", expires_in: 3599, scope: `${G}gmail.send ${G}gmail.modify` })
    if (req.url.startsWith("https://openidconnect.googleapis.com/v1/userinfo")) return ok({ sub: `sub-${user}`, email: opts.email ?? `${user}@example.com`, email_verified: true })
    if (req.url.startsWith(`${GMAIL}/history`) && opts.history) return opts.history()
    if (req.url.startsWith(`${GMAIL}/watch`)) return ok({ historyId: "10", expiration: String(Date.now() + 7 * 24 * 3600_000) })
    if (req.url.startsWith(`${GMAIL}/stop`)) return new Response(null, { status: stop() })
    if (req.url.startsWith("https://oauth2.googleapis.com/revoke")) return new Response("", { status: 200 })
    return new Response("not found", { status: 404 })
  }
  const connections = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
  await inDO(connections, async (instance) => {
    instance.http = http
  })
  const done = await op(token, "integration.complete", { state: new URL(c.value.authorize_url).searchParams.get("state")!, code: "c" })
  expect(done.ok).toBe(true)
  return { token, team, conn, connections, calls }
}

describe("users.stop is reliable", () => {
  it("disconnect retries users.stop before the revoke, and records a stop that never succeeds", async () => {
    let status = 500
    const { token, conn, connections, calls } = await linkGmail("stop-retry-1", () => status)
    await op(token, "integration.revoke", { connection: conn })
    let firstAt = 0
    await inDO(connections, async (instance, s) => {
      await instance.revokeAtProviders(Date.now() + 5 * 60_000)
      const row = s.storage.sql.exec("SELECT stop_done, first_at FROM pending_revocations").one() as { stop_done: number; first_at: number }
      expect(row.stop_done).toBe(0)
      firstAt = Number(row.first_at)
    })
    // The grant is not revoked while users.stop is still being retried (the token is needed for the stop).
    expect(calls.filter((c) => c.endsWith("/stop")).length).toBeGreaterThanOrEqual(1)
    expect(calls.some((c) => c.includes("/revoke"))).toBe(false)
    // Past the stop window: the failure is recorded, then the revoke goes ahead.
    await inDO(connections, async (instance, s) => {
      await instance.revokeAtProviders(firstAt + STOP_BEFORE_REVOKE_MS + 60_000)
      expect(s.storage.sql.exec("SELECT connection FROM watch_stop_failures").toArray()).toEqual([{ connection: conn }])
      expect(s.storage.sql.exec("SELECT * FROM pending_revocations").toArray()).toHaveLength(0)
    })
    expect(calls.some((c) => c.includes("/revoke"))).toBe(true)
    status = 204
  })

  it("disconnect stops first, then revokes, when users.stop succeeds on a retry", async () => {
    let status = 503
    const { token, conn, connections, calls } = await linkGmail("stop-retry-2", () => status)
    await op(token, "integration.revoke", { connection: conn })
    await inDO(connections, async (instance) => {
      await instance.revokeAtProviders(Date.now() + 5 * 60_000)
    })
    expect(calls.some((c) => c.includes("/revoke"))).toBe(false)
    status = 204
    await inDO(connections, async (instance, s) => {
      await settle(instance, s, Date.now() + 60 * 60_000)
      expect(s.storage.sql.exec("SELECT * FROM pending_revocations").toArray()).toHaveLength(0)
      expect(s.storage.sql.exec("SELECT * FROM watch_stop_failures").toArray()).toHaveLength(0)
    })
    const stopAt = calls.lastIndexOf(`POST ${GMAIL}/stop`)
    const revokeAt = calls.findIndex((c) => c.includes("/revoke"))
    expect(stopAt).toBeGreaterThanOrEqual(0)
    expect(revokeAt).toBeGreaterThan(stopAt)
  })

  it("a closed restricted-scope gate stops the watch with the connection's own token, retrying until it succeeds", async () => {
    let status = 500
    const { conn, connections, calls } = await linkGmail("stop-gate-1", () => status)
    let saved: unknown
    await inDO(connections, async (instance, s) => {
      saved = instance.env
      instance.env = { ...instance.env, GOOGLE_RESTRICTED_SCOPES: undefined }
      s.storage.sql.exec("UPDATE google_watches SET renew_at = ?", Date.now() - 1)
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, Date.now())
      const row = s.storage.sql.exec("SELECT stop_since, stop_failures FROM google_watches WHERE connection = ?", conn).one() as { stop_since: number | null; stop_failures: number }
      expect(row.stop_since).not.toBeNull()
      expect(row.stop_failures).toBe(1)
      status = 204
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, Date.now() + 3600_000)
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(0)
      expect(s.storage.sql.exec("SELECT * FROM watch_stop_failures").toArray()).toHaveLength(0)
      instance.env = saved
    })
    expect(calls.filter((c) => c === `POST ${GMAIL}/stop`)).toHaveLength(2)
  })

  it("renewWatchSoon makes the alarm renew the watch at once", async () => {
    const { team, conn, connections, calls } = await linkGmail("stop-renew-1", () => 204)
    const watches = () => calls.filter((c) => c === `POST ${GMAIL}/watch`).length
    expect(watches()).toBe(1)
    await connections.watchSoon(team, conn, "renew")
    for (const end = Date.now() + 5000; watches() < 2 && Date.now() < end; ) await new Promise((r) => setTimeout(r, 25))
    expect(watches()).toBe(2)
    await inDO(connections, async (_i, s) => {
      const row = s.storage.sql.exec("SELECT renew_at FROM google_watches WHERE connection = ?", conn).one() as { renew_at: number }
      expect(row.renew_at).toBeGreaterThan(Date.now())
    })
  })
})

describe("Pub/Sub delivery failures are isolated per link", () => {
  it("answers 503 for a failing link until it is dead-lettered, then 204; a success resets the count", async () => {
    const address = "dead-letter@example.com"
    const team = "team_deadletter0000000"
    const index = testEnv.ACCOUNT_INDEX_DO.get(testEnv.ACCOUNT_INDEX_DO.idFromName(`gmail:email:${address}`))
    await index.add(team, "conn_deadletter000000000")
    // A connection object whose push handoff throws (the RPC rejects), simulated on the class for this team only.
    const any = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team))
    let fail = true
    let original: any
    await inDO(any, async (instance) => {
      const proto = Object.getPrototypeOf(instance)
      original = proto.googlePush
      proto.googlePush = async function (this: unknown, entity: string, p: unknown) {
        if (entity === team && fail) throw new Error("broken connection object")
        return original.call(this, entity, p)
      }
    })
    const statuses: Array<number> = []
    for (let i = 0; i < LINK_DEAD_AFTER + 1; i++) statuses.push((await push(address)).status)
    expect(statuses).toEqual([...Array(LINK_DEAD_AFTER - 1).fill(503), 204, 204])
    fail = false
    expect((await push(address)).status).toBe(204)
    fail = true
    expect((await push(address)).status).toBe(503)
    await inDO(any, async (instance) => {
      Object.getPrototypeOf(instance).googlePush = original
    })
  })
})

/**
 * Drains revocations until none is left. The attempt that starts right after a
 * disconnect may still hold the mailbox's stop claim; a drain then answers
 * busy and retries, as the alarm would.
 */
const settle = async (instance: any, s: DurableObjectState, at: number) => {
  for (let i = 0; i < 80; i++) {
    await instance.revokeAtProviders(at)
    if (Number((s.storage.sql.exec("SELECT COUNT(*) AS n FROM pending_revocations").one() as { n: number }).n) === 0) return
    await new Promise((r) => setTimeout(r, 25))
  }
}

const failures = async (connections: any) => {
  let rows: Array<{ connection: string; reason: string }> = []
  await inDO(connections, async (_i, s) => {
    rows = s.storage.sql.exec("SELECT connection, reason FROM watch_stop_failures").toArray() as typeof rows
  })
  return rows
}

describe("users.stop follow-ups", () => {
  it("a 401 on users.stop is permanent at disconnect: recorded at once, the revoke goes ahead", async () => {
    const { token, conn, connections, calls } = await linkGmail("stop-401-1", () => 401)
    await op(token, "integration.revoke", { connection: conn })
    await inDO(connections, async (instance, s) => {
      await settle(instance, s, Date.now() + 5 * 60_000)
      expect(s.storage.sql.exec("SELECT * FROM pending_revocations").toArray()).toHaveLength(0)
    })
    expect((await failures(connections)).map((f) => f.connection)).toEqual([conn])
    expect(calls.some((c) => c.includes("/revoke"))).toBe(true)
  })

  it("a missing KEK at disconnect records the stop failure", async () => {
    const { token, conn, connections } = await linkGmail("stop-nokek-1", () => 204)
    await op(token, "integration.revoke", { connection: conn })
    await inDO(connections, async (instance) => {
      const saved = instance.env
      instance.env = { ...saved, INTEGRATIONS_KEK: undefined }
      await instance.revokeAtProviders(Date.now() + 5 * 60_000)
      instance.env = saved
    })
    expect((await failures(connections))[0]).toMatchObject({ connection: conn, reason: expect.stringMatching(/INTEGRATIONS_KEK/) })
  })

  it("a disconnect without a stored credential records the stop failure", async () => {
    const { token, conn, connections } = await linkGmail("stop-nocred-1", () => 204)
    await inDO(connections, async (_i, s) => {
      s.storage.sql.exec("DELETE FROM credentials WHERE connection = ?", conn)
    })
    await op(token, "integration.revoke", { connection: conn })
    for (const end = Date.now() + 3000; (await failures(connections)).length === 0 && Date.now() < end; ) await new Promise((r) => setTimeout(r, 25))
    expect((await failures(connections))[0]).toMatchObject({ connection: conn, reason: expect.stringMatching(/no stored credential/) })
  })

  it("a connection that is gone records the failure; one without an account still stops; a 401 or 24 h records", async () => {
    const gone = await linkGmail("stop-gone-1", () => 204)
    await inDO(gone.connections, async (instance, s) => {
      s.storage.sql.exec("UPDATE google_watches SET renew_at = ?", Date.now() - 1)
      await runWatchWork(instance.watchHost(), {}, Date.now())
    })
    expect((await failures(gone.connections))[0]).toMatchObject({ connection: gone.conn, reason: expect.stringMatching(/connection is gone/) })

    const noAccount = await linkGmail("stop-noacct-1", () => 204)
    await inDO(noAccount.connections, async (instance, s) => {
      const c = instance.boundEngine.currentState.connections[noAccount.conn]
      await ensureGmailWatch(instance.watchHost(), { ...c, account: null }, Date.now())
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(0)
    })
    expect(noAccount.calls.filter((c) => c === `POST ${GMAIL}/stop`)).toHaveLength(1)

    const refused = await linkGmail("stop-gate401-1", () => 401)
    await inDO(refused.connections, async (instance, s) => {
      const saved = instance.env
      instance.env = { ...saved, GOOGLE_RESTRICTED_SCOPES: undefined }
      s.storage.sql.exec("UPDATE google_watches SET renew_at = ?", Date.now() - 1)
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, Date.now())
      instance.env = saved
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(0)
    })
    expect((await failures(refused.connections))[0]?.connection).toBe(refused.conn)

    const slow = await linkGmail("stop-24h-1", () => 500)
    await inDO(slow.connections, async (instance, s) => {
      const saved = instance.env
      instance.env = { ...saved, GOOGLE_RESTRICTED_SCOPES: undefined }
      const now = Date.now()
      s.storage.sql.exec("UPDATE google_watches SET renew_at = ?", now - 1)
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, now)
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(1)
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, now + 24 * 3600_000)
      instance.env = saved
      expect(s.storage.sql.exec("SELECT * FROM google_watches").toArray()).toHaveLength(0)
    })
    expect((await failures(slow.connections))[0]?.connection).toBe(slow.conn)
  })

  it("two connections of one mailbox that disconnect together send one users.stop", async () => {
    const email = "shared-mailbox@example.com"
    const a = await linkGmail("stop-pair-a", () => 204, { email })
    const b = await linkGmail("stop-pair-b", () => 204, { email })
    await Promise.all([op(a.token, "integration.revoke", { connection: a.conn }), op(b.token, "integration.revoke", { connection: b.conn })])
    await Promise.all(
      [a, b].map((x) =>
        inDO(x.connections, async (instance, s) => {
          await settle(instance, s, Date.now() + 5 * 60_000)
        })
      )
    )
    const stops = [...a.calls, ...b.calls].filter((c) => c === `POST ${GMAIL}/stop`)
    expect(stops).toHaveLength(1)
  })

  it("a dead-lettered push schedules one history catch-up from the kept cursor", async () => {
    let reads = 0
    const x = await linkGmail("stop-catchup-1", () => 204, {
      history: () => {
        reads++
        return ok({ history: [], historyId: "10" })
      }
    })
    let original: any
    await inDO(x.connections, async (instance) => {
      const proto = Object.getPrototypeOf(instance)
      original = proto.googlePush
      proto.googlePush = async function (this: unknown, entity: string, p: unknown) {
        if (entity === x.team) throw new Error("broken handoff")
        return original.call(this, entity, p)
      }
    })
    try {
      for (let i = 0; i < LINK_DEAD_AFTER; i++) await push("stop-catchup-1@example.com")
      for (const end = Date.now() + 5000; reads < 1 && Date.now() < end; ) await new Promise((r) => setTimeout(r, 25))
      expect(reads).toBe(1)
    } finally {
      await inDO(x.connections, async (instance) => {
        Object.getPrototypeOf(instance).googlePush = original
      })
    }
  })

  it("a failing catch-up read never spins the alarm: its time moves out", async () => {
    const x = await linkGmail("stop-noloop-1", () => 204, { history: () => new Response("", { status: 503 }) })
    await inDO(x.connections, async (instance, s) => {
      const now = Date.now()
      await instance.watchSoon(x.team, x.conn, "catch_up")
      s.storage.sql.exec("UPDATE google_watches SET fallback_at = ?", now - 1)
      await runWatchWork(instance.watchHost(), instance.boundEngine.currentState.connections, now)
      const row = s.storage.sql.exec("SELECT fallback_at FROM google_watches").one() as { fallback_at: number }
      expect(row.fallback_at).toBeGreaterThan(now)
    })
  })

  it("rejects a Pub/Sub token older than 15 minutes (plus the 5 minute skew)", async () => {
    const res = await worker.fetch("https://api.test/v1/hooks/google/pubsub", {
      method: "POST",
      headers: { authorization: `Bearer ${await pubsubToken(Math.floor(Date.now() / 1000) - 30 * 60)}` },
      body: JSON.stringify({ message: { data: btoa(JSON.stringify({ emailAddress: "x@example.com", historyId: 1 })) } })
    })
    expect(res.status).toBe(401)
  })

  it("upgrades google_watches and links tables created before their new columns", async () => {
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName("team_upgrade_watches"))
    await inDO(stub, async (_i, s) => {
      s.storage.sql.exec("DROP TABLE IF EXISTS google_watches")
      s.storage.sql.exec(`CREATE TABLE google_watches (connection TEXT PRIMARY KEY, kind TEXT NOT NULL, owner TEXT NOT NULL, alias TEXT NOT NULL, cursor TEXT,
        expires_at INTEGER NOT NULL, renew_at INTEGER NOT NULL, failures INTEGER NOT NULL DEFAULT 0, fallback_at INTEGER)`)
      createWatchTable(s.storage.sql)
      createWatchTable(s.storage.sql)
      const cols = s.storage.sql.exec<{ name: string }>("PRAGMA table_info(google_watches)").toArray().map((c) => c.name)
      expect(cols).toEqual(expect.arrayContaining(["stop_since", "stop_failures"]))
      s.storage.sql.exec("DROP TABLE IF EXISTS links")
      s.storage.sql.exec("CREATE TABLE links (team TEXT NOT NULL, connection TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY (team, connection))")
      upgradeLinks(s.storage.sql)
      upgradeLinks(s.storage.sql)
      expect(s.storage.sql.exec<{ name: string }>("PRAGMA table_info(links)").toArray().map((c) => c.name)).toContain("failures")
    })
  })
})
