import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"

/**
 * Build spaces (src/build-space.ts): one person signed in to nightly (no header) and two dev builds (dev:a, dev:b).
 * Each build sees only its own Home inbox, conversations and registered hosts; the account-wide data (the team and its
 * members) is the same object for all three; an install token works only in the space that minted it.
 */
const raw = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
/** The raw bindings: names here are the full object names (`dev:<slug>|<name>` for a dev build's objects). */
const objects = env as unknown as { USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace; CONVERSATION_DO: DurableObjectNamespace }
/** Untyped stubs: runInDurableObject over a typed RPC stub is too deep for the checker. */
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const worker = (exports as unknown as { default: Fetcher }).default
const SPACES = ["", "dev:a", "dev:b"] as const
type Space = (typeof SPACES)[number]

const session = async (sub: string) =>
  new SignJWT({ email: `${sub}@spaces.test`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${raw.STACK_PROJECT_ID}`)
    .setAudience(raw.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(raw.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

const send = async (space: Space | "bad", path: string, token: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...(space === "bad" ? { "x-cmux-build-space": "Dev:Not A Tag" } : space ? { "x-cmux-build-space": space } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
const op = (space: Space, token: string, name: string, params: unknown) => send(space, "/v1/ops", token, { op: name, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const read = (space: Space, token: string, name: string, params: unknown) => send(space, "/v1/read", token, { op: name, params })

const b64u = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** Registers a Mac install in `space` and mints its token there. */
const macInstall = async (space: Space, token: string, user: string) => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await op(space, token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: `mac ${space || "nightly"}`, device_name: "Mac", platform: "macos" })
  expect(reg.status, JSON.stringify(reg.json)).toBe(200)
  const install = reg.json.value.id as string
  const mint = async (at: Space) => {
    const ch = await send(at, "/v1/auth/challenge", undefined, { user, install })
    if (ch.status !== 200) return { status: ch.status }
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
    const t = await send(at, "/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
    return { status: t.status, token: t.json?.access_token as string | undefined }
  }
  const minted = await mint(space)
  expect(minted.status).toBe(200)
  return { install, token: minted.token!, mint }
}

/** One person signed in to nightly, dev:a and dev:b: each with a Mac install, a conversation and a registered host. */
type Person = { user: string; team: string; install: string; installToken: string; conversation: string; host: string; mint: (at: Space) => Promise<{ status: number; token?: string }> }
let fixture: Promise<{ token: string; per: Record<string, Person> }> | undefined
const people = () => (fixture ??= (async () => {
    const sub = `spaces-${crypto.randomUUID().slice(0, 8)}`
    const token = await session(sub)
    const per: Record<string, Person> = {}
    for (const space of SPACES) {
      const ensured = await op(space, token, "user.ensure", {})
      expect(ensured.status, JSON.stringify(ensured.json)).toBe(200)
      const user = ensured.json.value.id as string
      const team = ensured.json.value.personal_team as string
      const mac = await macInstall(space, token, user)
      const created = await op(space, token, "conversation.create", { title: `chat ${space || "nightly"}`, participants: [{ id: user, kind: "human", display_name: sub }] })
      expect(created.status, JSON.stringify(created.json)).toBe(200)
      const host = await op(space, mac.token, "host.enroll", { name: `host ${space || "nightly"}`, platform: "macos" })
      expect(host.status, JSON.stringify(host.json)).toBe(200)
      per[space] = { user, team, install: mac.install, installToken: mac.token, conversation: created.json.value.conversation.id, host: host.json.value.id, mint: mac.mint }
    }
    return { token, per }
  })())

describe("build spaces (dev builds do not intertwine)", () => {
  it("keeps one person's inbox, conversations, hosts and installs apart per space; the team is shared", async () => {
    const { token, per } = await people()
    // The same person and the same personal team in every space.
    expect(new Set(SPACES.map((s) => per[s]!.user)).size).toBe(1)
    expect(new Set(SPACES.map((s) => per[s]!.team)).size).toBe(1)

    for (const space of SPACES) {
      const mine = per[space]!
      const others = SPACES.filter((s) => s !== space).map((s) => per[s]!)
      // Home inbox: only this build's conversation.
      const inbox = await read(space, token, "inbox.list", { limit: 50 })
      expect(inbox.status, JSON.stringify(inbox.json)).toBe(200)
      const listed = (inbox.json.value.entries as Array<{ conversation: string }>).map((e) => e.conversation)
      expect(listed).toContain(mine.conversation)
      for (const o of others) expect(listed).not.toContain(o.conversation)
      // Another build's conversation does not exist here.
      for (const o of others) {
        const h = await read(space, token, "conversation.history", { conversation: o.conversation, limit: 10 })
        expect(h.json?.ok === true && (h.json.value?.messages?.length ?? 0) > 0).toBe(false)
      }
      // Hosts: only this build's Mac, in the one shared team.
      const hosts = await read(space, token, "team.hosts.list", {})
      expect(hosts.status, JSON.stringify(hosts.json)).toBe(200)
      expect(hosts.json.value.team).toBe(mine.team)
      expect((hosts.json.value.hosts as Array<{ id: string }>).map((h) => h.id)).toEqual([mine.host])
      // The count matches the list: nightly's counts no dev build's host (review follow-up).
      expect(hosts.json.value.host_count).toBe(1)
      const directory = await read(space, token, "team.directory", {})
      expect((directory.json.value.hosts as Array<{ id: string }>).map((h) => h.id)).toEqual([mine.host])
      // Another build's host cannot be removed from here.
      for (const o of others) expect((await op(space, token, "host.remove", { host: o.host })).json.error?.code).toBe("selector.not_found")
      // Install tokens work only where they were minted: anywhere else the install is unknown.
      for (const s of SPACES.filter((x) => x !== space)) {
        expect((await read(s, mine.installToken, "team.hosts.list", {})).status).toBe(401)
        expect((await mine.mint(s)).status).not.toBe(200)
      }
    }
    // Account-wide: the team's members are the same object and answer the same everywhere.
    const members = await Promise.all(SPACES.map(async (s) => (await read(s, token, "team.members.list", {})).json.value.members))
    expect(members[1]).toEqual(members[0])
    expect(members[2]).toEqual(members[0])

  })

  it("a shared TeamDO sees a per-build object's own principals in that object's space", async () => {
    const { per } = await people()
    const user = per[""]!.user, team = per[""]!.team
    // A principal a per-build object builds for itself (a chief's, a system one) carries no build_space, yet the
    // shared TeamDO sees it in the space of the object that called (build-space.ts principalsInSpace).
    for (const space of ["dev:a", "dev:b"] as const) {
      const listed = await inDO(objects.USER_DO.get(objects.USER_DO.idFromName(`${space}|${user}`)), async (instance) => {
        const stub = instance.env.TEAM_DO.get(instance.env.TEAM_DO.idFromName(team))
        const r = await stub.readOp(team, { identity: `agent:chief_test`, kind: "agent", agent: "chief_test", user }, "team.hosts.list", {})
        return (r.value?.hosts ?? []).map((h: { id: string }) => h.id)
      })
      expect(listed).toEqual([per[space]!.host])
    }
  })

  it("checks a presence proof in the requester's space, where its challenge was made", async () => {
    const { per } = await people()
    const user = per[""]!.user, team = per[""]!.team
    // Presence: challenge and assert reach the UserDO of the requester's space, never nightly's.
    const presence = await inDO(objects.TEAM_DO.get(objects.TEAM_DO.idFromName(team)), async (instance) => [
      instance.presenceUser(user, "dev:a").id.toString(),
      instance.presenceUser(user, "").id.toString()
    ])
    expect(presence).toEqual([objects.USER_DO.idFromName(`dev:a|${user}`).toString(), objects.USER_DO.idFromName(user).toString()])
  })

  it("keeps a dev build's attachments under its own space's bucket prefix", async () => {
    const { per } = await people()
    // Attachments: a dev build's conversation stores its objects under its own space's prefix.
    const keys = await inDO(objects.CONVERSATION_DO.get(objects.CONVERSATION_DO.idFromName(`dev:a|${per["dev:a"]!.conversation}`)), async (instance) =>
      instance.attachmentKeyPrefix(per["dev:a"]!.conversation))
    expect(keys).toBe(`home/v1/dev:a|${per["dev:a"]!.conversation}/`)
  })

  it("refuses a malformed space header instead of reading it as nightly", async () => {
    const r = await send("bad", "/v1/health", undefined)
    expect(r.status).toBe(400)
    expect(r.json.error.code).toBe("build_space.invalid")
  })

})
