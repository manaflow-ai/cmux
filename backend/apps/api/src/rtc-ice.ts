import { authenticate } from "./auth.ts"
import type { Env } from "./env.ts"

/** Cloudflare's public STUN server; free and needs no credentials. */
export const CLOUDFLARE_STUN = "stun:stun.cloudflare.com:3478"
/** Credential lifetime: one working day; clients refresh in-session with setConfiguration. */
export const ICE_TTL_SECONDS = 12 * 60 * 60

export interface IceServer {
  readonly urls: ReadonlyArray<string>
  readonly username?: string
  readonly credential?: string
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

/**
 * `GET /v1/rtc/ice-servers` (bearer): short-lived Cloudflare TURN credentials for one of the
 * user's devices (plans/cmux-next/ios-rtc.md section 4). The TURN key's API token stays here.
 * Without TURN configured the answer is STUN only and `turn: false`, so a client on a symmetric
 * NAT knows why it cannot connect instead of timing out silently.
 */
export const handleIceServers = async (request: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> => {
  if (request.method !== "GET") return json(405, { code: "validation.invalid", message: "GET only" })
  const header = request.headers.get("Authorization") ?? ""
  const token = header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : undefined
  const principal = await authenticate(env, token)
  if (!principal?.user) return json(401, { code: "auth.unauthenticated", message: "missing or invalid bearer token" })
  const stunOnly = { ice_servers: [{ urls: [CLOUDFLARE_STUN] }], ttl: ICE_TTL_SECONDS, turn: false }
  if (!env.CF_TURN_KEY_ID || !env.CF_TURN_API_TOKEN) return json(200, stunOnly)
  try {
    const res = await fetcher(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.CF_TURN_KEY_ID)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.CF_TURN_API_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl: ICE_TTL_SECONDS })
    })
    if (!res.ok) throw new Error(`cloudflare turn ${res.status}`)
    const body = (await res.json()) as { iceServers?: ReadonlyArray<{ urls?: unknown; username?: unknown; credential?: unknown }> }
    const servers: Array<IceServer> = []
    for (const s of body.iceServers ?? []) {
      const urls = (Array.isArray(s.urls) ? s.urls : [s.urls]).filter((u): u is string => typeof u === "string")
      // Port 53 URLs are blocked by browsers and many networks; the other ports cover the same paths.
      const usable = urls.filter((u) => !/:53(\?|$)/.test(u))
      if (usable.length === 0) continue
      servers.push({ urls: usable, ...(typeof s.username === "string" ? { username: s.username } : {}), ...(typeof s.credential === "string" ? { credential: s.credential } : {}) })
    }
    if (!servers.some((s) => s.urls.some((u) => u.startsWith("stun:")))) servers.unshift({ urls: [CLOUDFLARE_STUN] })
    return json(200, { ice_servers: servers, ttl: ICE_TTL_SECONDS, turn: servers.some((s) => s.urls.some((u) => u.startsWith("turn"))) })
  } catch (e) {
    console.error(JSON.stringify({ msg: "rtc ice-servers: turn mint failed", error: String(e) }))
    return json(200, { ...stunOnly, turn_error: "unavailable" })
  }
}
