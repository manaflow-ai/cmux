import { createExecutionContext, env as workerEnv, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { cachedIceServers, hopServers, STUN } from "../src/ice.ts"

const bindings = () => ({
  ...workerEnv, ENVIRONMENT: "test", TURN_KEY_ID: crypto.randomUUID(), TURN_KEY_API_TOKEN: "test-token", ICE_TTL_SECONDS: "300"
} as Env)
const minted = (name: string) => Response.json({ iceServers: [{ urls: ["turn:relay.test:3478"], username: name, credential: "test" }] })
afterEach(() => vi.restoreAllMocks())

it("retains TURN across a failed refresh, then refuses it inside the expiry margin", async () => {
  const env = bindings()
  const now = Date.now()
  const time = vi.spyOn(Date, "now").mockReturnValue(now)
  const fetcher = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(minted("first")).mockImplementation(async () => new Response(null, { status: 503 }))
  const ctx = createExecutionContext()
  expect((await cachedIceServers(env, ctx)).turn).toBe(true)
  await waitOnExecutionContext(ctx)

  time.mockReturnValue(now + 151_000)
  const stale = createExecutionContext()
  const hits = await Promise.all([cachedIceServers(env, stale), cachedIceServers(env, stale)])
  for (const hit of hits) {
    expect(hit).toMatchObject({ turn: true, ttl: 149 })
    expect(hit.iceServers).toContainEqual(expect.objectContaining({ username: "first" }))
  }
  await waitOnExecutionContext(stale)
  expect(fetcher).toHaveBeenCalledTimes(2)
  const retry = createExecutionContext()
  expect((await cachedIceServers(env, retry)).turn).toBe(true)
  await waitOnExecutionContext(retry)

  time.mockReturnValue(now + 270_000)
  const expired = createExecutionContext()
  expect(await cachedIceServers(env, expired)).toMatchObject({ turn: false, iceServers: [{ urls: [STUN] }] })
  fetcher.mockResolvedValueOnce(minted("replacement"))
  expect((await cachedIceServers(env, expired)).iceServers).toContainEqual(expect.objectContaining({ username: "replacement" }))
  await waitOnExecutionContext(expired)
})

it("mints scoped hop tickets only when a PoP and secret are configured", async () => {
  const env = { ...bindings(), HOP_RELAY_URL: "hop://relay.example:7422", HOP_RELAY_TICKET_SECRET: "s".repeat(32) }
  const [first] = await hopServers(env, 3600)
  const [second] = await hopServers(env, 3600)
  expect(first?.url).toBe(env.HOP_RELAY_URL)
  expect(first?.ticket).toMatch(/^hop1\.[0-9a-f-]{36}\.\d+\.[A-Za-z0-9_-]+$/)
  expect(second?.ticket).not.toBe(first?.ticket)
  expect(await hopServers({ ...env, HOP_RELAY_TICKET_SECRET: "short" }, 3600)).toEqual([])
})

it("separates TURN keys and environments and requires the minting bindings", async () => {
  const env = bindings()
  const ctx = createExecutionContext()
  const fetcher = vi.spyOn(globalThis, "fetch")
  for (const [bindings, name] of [[env, "first"], [{ ...env, ENVIRONMENT: "other" }, "second"], [{ ...env, TURN_KEY_ID: crypto.randomUUID() }, "third"]] as const) {
    fetcher.mockResolvedValueOnce(minted(name))
    expect((await cachedIceServers(bindings, ctx)).iceServers).toContainEqual(expect.objectContaining({ username: name }))
  }
  expect((await cachedIceServers({ ...env, TURN_KEY_API_TOKEN: undefined }, ctx)).turn).toBe(false)
  await waitOnExecutionContext(ctx)
  expect(fetcher).toHaveBeenCalledTimes(3)
})

it("returns STUN on a cold deadline and keeps a late TURN mint for the next caller", async () => {
  const env = bindings()
  const ctx = createExecutionContext()
  let finish!: (response: Response) => void
  const slow = new Promise<Response>((resolve) => { finish = resolve })
  const fetcher = vi.spyOn(globalThis, "fetch").mockReturnValueOnce(slow)
  const fallback = await cachedIceServers(env, ctx)
  expect(fallback).toMatchObject({ turn: false, ttl: 60, iceServers: [{ urls: [STUN] }] })
  finish(minted("late"))
  await waitOnExecutionContext(ctx)
  const next = createExecutionContext()
  expect((await cachedIceServers(env, next)).iceServers).toContainEqual(expect.objectContaining({ username: "late" }))
  expect(fetcher).toHaveBeenCalledTimes(1)
  await waitOnExecutionContext(next)
})

it("includes a slow shared lookup in the cold deadline and reuses its eventual hit", async () => {
  const issuedAt = Date.now()
  const entry = {
    issuedAt, usableUntil: issuedAt + 270_000,
    answer: { turn: true, ttl: 300, iceServers: [{ urls: ["turn:relay.test:3478"], username: "stored", credential: "test" }] }
  }
  let found!: (value: typeof entry) => void
  const lookup = new Promise<typeof entry>((resolve) => { found = resolve })
  const readIce = vi.fn(() => lookup)
  const env = { ...bindings(), TEAM_HUB: { idFromName: () => "cache", get: () => ({ readIce }) } } as unknown as Env
  const fetcher = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("unexpected mint"))
  const ctx = createExecutionContext()
  const fallback = await cachedIceServers(env, ctx)
  expect(fallback.turn).toBe(false)
  found(entry)
  await waitOnExecutionContext(ctx)
  const next = createExecutionContext()
  expect((await cachedIceServers(env, next)).iceServers).toEqual(entry.answer.iceServers)
  expect(readIce).toHaveBeenCalledTimes(1)
  expect(fetcher).not.toHaveBeenCalled()
  await waitOnExecutionContext(next)
})

it("mints credentials for our own relay without calling Cloudflare", async () => {
  const env = { ...bindings(), TURN_SELF_URLS: "turn:relay.test:3478?transport=udp, turn:relay.test:443?transport=udp, turns:relay.test:443?transport=tcp", TURN_SELF_SECRET: "s3cret" } as Env
  const fetcher = vi.spyOn(globalThis, "fetch")
  const now = Date.now()
  const answer = await cachedIceServers(env, createExecutionContext())
  expect(fetcher).not.toHaveBeenCalled()
  expect(answer.turn).toBe(true)
  const own = answer.iceServers.find((s) => s.urls.some((u) => u.startsWith("turns:")))!
  expect(own.urls).toEqual(["turn:relay.test:3478?transport=udp", "turn:relay.test:443?transport=udp", "turns:relay.test:443?transport=tcp"])
  const [exp] = own.username!.split(":")
  expect(Number(exp)).toBeGreaterThan(Math.floor(now / 1000) + 299)
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("s3cret"), { name: "HMAC", hash: "SHA-1" }, false, ["verify"])
  const mac = Uint8Array.from(atob(own.credential!), (c) => c.charCodeAt(0))
  expect(await crypto.subtle.verify("HMAC", key, mac, new TextEncoder().encode(own.username!))).toBe(true)
})

it("keeps Cloudflare on the cached path when no own-relay URL is accepted", async () => {
  const env = { ...bindings(), TURN_SELF_URLS: "relay.test, https://relay.test", TURN_SELF_SECRET: "s3cret" } as Env
  const fetcher = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(minted("cloudflare"))
  const ctx = createExecutionContext()
  const answers = [await cachedIceServers(env, ctx), await cachedIceServers(env, ctx)]
  for (const answer of answers) expect(answer.iceServers).toContainEqual(expect.objectContaining({ username: "cloudflare" }))
  await waitOnExecutionContext(ctx)
  expect(fetcher).toHaveBeenCalledTimes(1)
})
