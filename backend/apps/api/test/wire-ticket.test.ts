import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it, vi } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

/**
 * cx-dgsp: the wire socket's credential stays out of the invocation log. Through the Worker's own
 * fetch: a browser mints a single-use ticket with the Authorization header and sends only
 * `ticket.<ticket>`; a native client sends the Authorization header on the upgrade. The legacy
 * `bearer.<token>` subprotocol is retired: it authenticates nothing.
 */
const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

const stackToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const person = async (tag: string) => {
  const sub = `wt-${tag}-${crypto.randomUUID().slice(0, 8)}`
  const token = await stackToken(sub)
  const r = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID() }) })
  expect(r.status).toBe(200)
  return { token, user: userIdFor(testEnv.STACK_PROJECT_ID, sub) }
}

const mint = async (token?: string, scope?: string) => {
  const r = await worker.fetch("https://api.test/v1/wire/ticket", {
    method: "POST",
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(scope ? { "content-type": "application/json" } : {}) },
    ...(scope ? { body: JSON.stringify({ scope }) } : {}),
  })
  return { status: r.status, body: (await r.json()) as { ticket?: string; expires_at?: number } }
}

const upgrade = (path: string, protocols: string, extra: Record<string, string> = {}) =>
  worker.fetch(`https://api.test${path}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": protocols, ...extra } })

/** Accepts a 101 socket and returns the user its welcome frame names. */
const welcomeUser = async (res: Response): Promise<string> => {
  expect(res.status).toBe(101)
  expect(res.headers.get("Sec-WebSocket-Protocol")).toBe("cmux.wire.v1")
  const ws = res.webSocket!
  const welcome = new Promise<any>((resolve) => ws.addEventListener("message", (e) => resolve(JSON.parse(e.data as string))))
  ws.accept()
  const frame = await welcome
  ws.close()
  expect(frame.t).toBe("welcome")
  return frame.principal.user as string
}

const expectRefused = async (res: Response) => {
  expect(res.status).toBe(401)
  expect(res.webSocket).toBeNull()
  expect(res.headers.get("x-cmux-wire-auth")).toBe("authorization, ticket")
  await res.arrayBuffer()
}

/** The shard and storage key of a ticket, as wire-ticket.ts derives them. */
const shard = async (ticket: string) => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ticket)))
  const ns = testEnv.WIRE_TICKET_DO
  return { stub: ns.get(ns.idFromName(`wire-ticket:${digest[0]}`)), key: Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("") }
}

describe("wire credentials outside Sec-WebSocket-Protocol (cx-dgsp)", () => {
  it("a ticket opens one socket as the person who minted it; storage holds only the ticket's hash", async () => {
    const a = await person("a")
    const m = await mint(a.token)
    expect(m.status).toBe(200)
    expect(m.body.ticket).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(m.body.expires_at! - Date.now()).toBeLessThanOrEqual(30_000)
    const { stub, key } = await shard(m.body.ticket!)
    const stored = await runInDurableObject(stub, async (_i, state) => [...(await state.storage.list()).keys()])
    expect(stored).toContain(key)
    expect(stored).not.toContain(m.body.ticket)
    expect(await welcomeUser(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${m.body.ticket}`))).toBe(a.user)
    // Spent: the record is gone and the same ticket is refused.
    expect(await runInDurableObject(stub, async (_i, state) => (await state.storage.get(key)) ?? null)).toBeNull()
    await expectRefused(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${m.body.ticket}`))
  })

  it("an expired ticket is refused", async () => {
    const a = await person("exp")
    const m = await mint(a.token)
    const { stub, key } = await shard(m.body.ticket!)
    await runInDurableObject(stub, async (_i, state) => {
      const r = (await state.storage.get(key)) as { principal: Principal; expires_at: number }
      await state.storage.put(key, { ...r, expires_at: Date.now() - 1 })
    })
    await expectRefused(await upgrade("/v1/wire/feed", `cmux.wire.v1, ticket.${m.body.ticket}`))
  })

  it("a forged or malformed ticket is refused", async () => {
    const forged = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    await expectRefused(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${forged}`))
    await expectRefused(await upgrade("/v1/wire/user", "cmux.wire.v1, ticket.not-a-ticket"))
    await expectRefused(await upgrade("/v1/wire/user", "cmux.wire.v1"))
  })

  it("a ticket carries its minter's identity only: it opens no socket of another person, and a second credential cannot change it", async () => {
    const a = await person("owner")
    const b = await person("other")
    // A conversation with B as its only participant: A's ticket cannot open it.
    const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    const id = `conv_${Array.from(crypto.getRandomValues(new Uint8Array(26)), (b) => crockford[b % 32]).join("")}`
    const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<unknown> }
    const bSession: Principal = { kind: "session", identity: `session:${b.user}`, user: b.user, team: personalTeamIdFor(b.user), display_name: "B", email: "b@example.com", email_verified: true }
    await conv.submit(id, bSession, { t: "op", op: "conversation.create", params: { id, kind: "group", title: "B only", participants: [{ id: b.user, kind: "human", display_name: "B" }] }, idempotency_key: "c" })
    const forA = await mint(a.token)
    const refused = await upgrade(`/v1/wire/conv/${id}`, `cmux.wire.v1, ticket.${forA.body.ticket}`)
    expect(refused.status).toBe(403)
    await refused.arrayBuffer()
    // A's ticket with B's legacy bearer beside it still opens A's socket, never B's.
    const forA2 = await mint(a.token)
    expect(await welcomeUser(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${forA2.body.ticket}, bearer.${b.token}`))).toBe(a.user)
  })

  it("a ticket opens only the socket scope it was minted for, and is spent by a refused try", async () => {
    const a = await person("scope")
    const feed = await mint(a.token, "feed")
    expect(feed.status).toBe(200)
    await expectRefused(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${feed.body.ticket}`))
    // The refused try spent it: the right socket refuses it too.
    await expectRefused(await upgrade("/v1/wire/feed", `cmux.wire.v1, ticket.${feed.body.ticket}`))
    expect(await welcomeUser(await upgrade("/v1/wire/feed", `cmux.wire.v1, ticket.${(await mint(a.token, "feed")).body.ticket}`))).toBe(a.user)
    // A ticket minted without a scope is a user-socket ticket (the scope before tickets were bound).
    await expectRefused(await upgrade("/v1/wire/feed", `cmux.wire.v1, ticket.${(await mint(a.token)).body.ticket}`))
    expect(await welcomeUser(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${(await mint(a.token)).body.ticket}`))).toBe(a.user)
    // An unknown scope mints nothing.
    expect((await mint(a.token, "pair")).status).toBe(400)
  })

  it("minting needs the Authorization header", async () => {
    expect((await mint()).status).toBe(401)
    const a = await person("mint")
    const viaProtocol = await worker.fetch("https://api.test/v1/wire/ticket", { method: "POST", headers: { "Sec-WebSocket-Protocol": `bearer.${a.token}` } })
    expect(viaProtocol.status).toBe(401)
    await viaProtocol.arrayBuffer()
  })

  it("a native client's Authorization header opens the socket with no credential in the subprotocols", async () => {
    const a = await person("native")
    expect(await welcomeUser(await upgrade("/v1/wire/user", "cmux.wire.v1", { authorization: `Bearer ${a.token}` }))).toBe(a.user)
    await expectRefused(await upgrade("/v1/wire/user", "cmux.wire.v1", { authorization: "Bearer not-a-token" }))
  })

  it("the upgrade forwarded to the owner object carries no credential: no Authorization, no bearer. or ticket. subprotocol", async () => {
    const a = await person("forward")
    const ns = testEnv.USER_DO as unknown as { get(id: DurableObjectId): { fetch(r: Request): Promise<Response> } }
    const get = ns.get.bind(ns)
    const forwarded: Array<Request> = []
    const spy = vi.spyOn(ns, "get").mockImplementation((id) => {
      const stub = get(id)
      return new Proxy(stub, { get: (t, k) => (k === "fetch" ? (r: Request) => (forwarded.push(r), t.fetch(r)) : Reflect.get(t, k)) })
    })
    try {
      const res = await upgrade("/v1/wire/user", "cmux.wire.v1, bearer.x, ticket.y", { authorization: `Bearer ${a.token}` })
      // The stray ticket is spent at the entry (and refused), so a stray bearer. beside the header proves the strip.
      await res.arrayBuffer()
      const native = await upgrade("/v1/wire/user", "cmux.wire.v1, bearer.x", { authorization: `Bearer ${a.token}` })
      expect(await welcomeUser(native)).toBe(a.user)
    } finally {
      spy.mockRestore()
    }
    expect(forwarded).toHaveLength(1)
    const headers = forwarded[0]!.headers
    expect(headers.get("authorization")).toBeNull()
    const protocols = (headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((p) => p.trim())
    expect(protocols).toEqual(["cmux.wire.v1"])
    expect(protocols.some((p) => p.startsWith("bearer.") || p.startsWith("ticket."))).toBe(false)
  })

  it("the retired bearer subprotocol opens nothing, and the 401 names header auth", async () => {
    const a = await person("legacy")
    const res = await upgrade("/v1/wire/user", `cmux.wire.v1, bearer.${a.token}`)
    expect(res.headers.get("x-cmux-wire-auth")).toBe("authorization, ticket")
    await expectRefused(res)
  })

  it("a ticket is spent by the first request that carries it, on any path", async () => {
    const a = await person("entry")
    const m = await mint(a.token)
    const elsewhere = await worker.fetch("https://api.test/v1/health", { headers: { "Sec-WebSocket-Protocol": `cmux.wire.v1, ticket.${m.body.ticket}` } })
    await elsewhere.arrayBuffer()
    await expectRefused(await upgrade("/v1/wire/user", `cmux.wire.v1, ticket.${m.body.ticket}`))
  })

  it("one person mints at most 60 tickets a minute", async () => {
    // The limit is a fixed 60 s window on the Worker's own limiter, keyed by the user id. Each minted ticket makes a
    // ticket shard object, and 60 real mints took 5 s on a loaded host, so 59 of the person's 60 are spent on that
    // limiter directly; the 60th and 61st go through the Worker. A run that crosses a minute boundary proves nothing,
    // so it runs once more for a new person; two short runs in a row never both cross one.
    for (let attempt = 0; ; attempt++) {
      const a = await person(`limit-${attempt}`)
      const minute = () => Math.floor(Date.now() / 60_000)
      const start = minute()
      await Promise.all(Array.from({ length: 59 }, () => testEnv.WIRE_TICKET_LIMIT!.limit({ key: a.user })))
      const sixtieth = await mint(a.token)
      const sixtyFirst = await mint(a.token)
      if (minute() !== start && attempt === 0) continue
      expect(sixtieth.status).toBe(200)
      expect(sixtyFirst.status).toBe(429)
      break
    }
    // Another person is not limited by the first.
    expect((await mint((await person("limit-other")).token)).status).toBe(200)
  })
})
