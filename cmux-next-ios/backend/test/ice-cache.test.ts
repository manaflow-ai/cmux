import { createExecutionContext, env as workerEnv, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"
import { cachedIceServers, STUN } from "../src/ice.ts"

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
