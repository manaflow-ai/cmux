import { describe, expect, it } from "vitest"
import { DEFAULT_MOBILE_CONFIG, mobileConfig } from "../src/mobile-config.ts"
import { handleTurn } from "../src/mobile-routes.ts"
import { iceServersOf, mintTurnCredentials, TURN_TTL_SECONDS } from "../src/realtime-turn.ts"
import { call, hostUser, testEnv } from "./host-control-support.ts"

/** TURN credential minting for B2 and the remote config for C16 (b1-control-do.md sections 6 and 7). */

const configured = { CLOUDFLARE_TURN_KEY_ID: "key-id-test", CLOUDFLARE_TURN_KEY_API_TOKEN: "token-test" }

describe("Cloudflare Realtime TURN credentials", () => {
  it("refuses with a typed error when the key is not configured", async () => {
    expect(await mintTurnCredentials({}, "in_a")).toEqual({ ok: false, code: "signal.turn_unavailable", message: "TURN is not configured on this deployment", retryable: false })
  })

  it("mints short-lived credentials from the configured key", async () => {
    const seen: Array<{ url: string; init: RequestInit }> = []
    const fake = (async (url: string, init: RequestInit) => {
      seen.push({ url, init })
      return Response.json({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp", "http://bogus"], username: "u1", credential: "c1" }] })
    }) as unknown as typeof fetch
    const r = await mintTurnCredentials(configured, "in_phone01", 1000, fake)
    expect(r).toEqual({ ok: true, value: { ice_servers: [{ urls: ["stun:stun.cloudflare.com:3478", "turn:turn.cloudflare.com:3478?transport=udp"], username: "u1", credential: "c1" }], expires_at: 1000 + TURN_TTL_SECONDS * 1000 } })
    expect(seen[0]!.url).toBe("https://rtc.live.cloudflare.com/v1/turn/keys/key-id-test/credentials/generate-ice-servers")
    expect((seen[0]!.init.headers as Record<string, string>).authorization).toBe("Bearer token-test")
    expect(JSON.parse(seen[0]!.init.body as string)).toEqual({ ttl: TURN_TTL_SECONDS })
  })

  it("reports upstream failures as retryable and accepts the single-object answer", async () => {
    const down = (async () => new Response("no", { status: 502 })) as unknown as typeof fetch
    expect(await mintTurnCredentials(configured, "in_a", 0, down)).toMatchObject({ ok: false, code: "signal.turn_unavailable", retryable: true })
    const denied = (async () => new Response("no", { status: 401 })) as unknown as typeof fetch
    expect(await mintTurnCredentials(configured, "in_a", 0, denied)).toMatchObject({ ok: false, retryable: false })
    expect(iceServersOf({ iceServers: { urls: "turns:turn.cloudflare.com:5349", username: "u", credential: "c" } })).toEqual([{ urls: ["turns:turn.cloudflare.com:5349"], username: "u", credential: "c" }])
  })

  it("limits the authenticated identity before calling the TURN provider", async () => {
    const u = await hostUser("turn-rate")
    let providerCalls = 0
    const env = Object.create(testEnv) as Record<string, unknown>
    env.MOBILE_TURN_LIMIT = { limit: async ({ key }: { key: string }) => ({ success: key === `turn:${u.phone.install}` }) }
    env.CLOUDFLARE_TURN_KEY_ID = configured.CLOUDFLARE_TURN_KEY_ID
    env.CLOUDFLARE_TURN_KEY_API_TOKEN = configured.CLOUDFLARE_TURN_KEY_API_TOKEN
    const request = new Request("https://api.test/v1/realtime/turn", { method: "POST", headers: { authorization: `Bearer ${u.phone.token}` } })
    const response = await handleTurn(request, env as never, (async () => {
      providerCalls++
      return Response.json({ iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] })
    }) as unknown as typeof fetch)
    expect(response.status).toBe(200)
    expect(providerCalls).toBe(1)

    env.MOBILE_TURN_LIMIT = { limit: async () => ({ success: false }) }
    const refused = await handleTurn(request, env as never, (async () => {
      providerCalls++
      return Response.json({ iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] })
    }) as unknown as typeof fetch)
    expect(refused.status).toBe(429)
    expect((await refused.json()) as unknown).toMatchObject({ ok: false, error: { code: "signal.rate_limited", retryable: true } })
    expect(refused.headers.get("retry-after")).toBe("60")
    expect(providerCalls).toBe(1)

    env.MOBILE_TURN_LIMIT = { limit: async () => { throw new Error("limiter unavailable") } }
    const unavailable = await handleTurn(request, env as never, (async () => {
      providerCalls++
      return Response.json({ iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }] })
    }) as unknown as typeof fetch)
    expect(unavailable.status).toBe(429)
    expect(providerCalls).toBe(1)
  })
})

describe("remote config", { timeout: 60_000 }, () => {
  it("serves defaults, merges the var and ignores a malformed one", () => {
    expect(mobileConfig({})).toBe(DEFAULT_MOBILE_CONFIG)
    const merged = mobileConfig({ MOBILE_REMOTE_CONFIG: JSON.stringify({ version: 3, flags: { "transport.webrtc_wg": true, "feed.inline_reply": 2, "Bad Name": true, "x.obj": { a: 1 } }, min_app_version: "1.2.3" }) })
    expect(merged).toEqual({ version: 3, flags: { ...DEFAULT_MOBILE_CONFIG.flags, "transport.webrtc_wg": true, "feed.inline_reply": 2 }, min_app_version: "1.2.3" })
    expect(mobileConfig({ MOBILE_REMOTE_CONFIG: "{not json" })).toBe(DEFAULT_MOBILE_CONFIG)
  })

  it("answers GET /v1/mobile/config for a signed-in install only", async () => {
    const u = await hostUser("cfg")
    const r = await call("/v1/mobile/config", u.phone.token, undefined, "GET")
    expect(r.status).toBe(200)
    expect(r.json).toEqual({ ok: true, value: DEFAULT_MOBILE_CONFIG })
    expect((await call("/v1/mobile/config", undefined, undefined, "GET")).status).toBe(401)
  })
})
