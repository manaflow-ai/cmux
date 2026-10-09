import type { Env } from "./env.ts"
import type { ReadAnswer } from "./mobile-session.ts"

/**
 * Cloudflare Realtime TURN credentials for lane B2 (b1-control-do.md section 6). One short-lived
 * credential per call, per install. The TURN key id and its API token are Worker secrets
 * (`CLOUDFLARE_TURN_KEY_ID`, `CLOUDFLARE_TURN_KEY_API_TOKEN`); they are never logged or returned.
 * Without them every call answers `signal.turn_unavailable`.
 */

export const TURN_TTL_SECONDS = 900
const TURN_API = "https://rtc.live.cloudflare.com/v1/turn/keys"

export interface IceServer {
  readonly urls: Array<string>
  readonly username?: string
  readonly credential?: string
}

export type TurnResult = { readonly ok: true; readonly value: { ice_servers: Array<IceServer>; expires_at: number } } | { readonly ok: false; readonly code: "signal.turn_unavailable"; readonly message: string; readonly retryable: boolean }

const URL_SCHEME = /^(stun|turn|turns):/

/** Normalizes Cloudflare's answer (`iceServers` as one object or a list) to the wire shape. */
export const iceServersOf = (body: unknown): Array<IceServer> => {
  const raw = (body as { iceServers?: unknown } | null)?.iceServers
  const list = Array.isArray(raw) ? raw : raw ? [raw] : []
  const out: Array<IceServer> = []
  for (const s of list as Array<Record<string, unknown>>) {
    const urls = (Array.isArray(s?.urls) ? s.urls : [s?.urls]).filter((u): u is string => typeof u === "string" && URL_SCHEME.test(u))
    if (urls.length === 0) continue
    out.push({ urls, ...(typeof s.username === "string" ? { username: s.username } : {}), ...(typeof s.credential === "string" ? { credential: s.credential } : {}) })
  }
  return out
}

/** Mints one credential set. `fetcher` is injectable for tests; production uses the global fetch. */
export const mintTurnCredentials = async (env: Pick<Env, "CLOUDFLARE_TURN_KEY_ID" | "CLOUDFLARE_TURN_KEY_API_TOKEN">, install: string, now = Date.now(), fetcher: typeof fetch = fetch): Promise<TurnResult> => {
  const keyId = env.CLOUDFLARE_TURN_KEY_ID
  const token = env.CLOUDFLARE_TURN_KEY_API_TOKEN
  if (!keyId || !token) return { ok: false, code: "signal.turn_unavailable", message: "TURN is not configured on this deployment", retryable: false }
  let res: Response
  try {
    res = await fetcher(`${TURN_API}/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      // Keep this request to Cloudflare's documented contract. The install identity is already
      // enforced and rate-limited by the Worker; it must not be sent to the TURN provider.
      body: JSON.stringify({ ttl: TURN_TTL_SECONDS })
    })
  } catch {
    return { ok: false, code: "signal.turn_unavailable", message: "TURN provider unreachable", retryable: true }
  }
  if (!res.ok) {
    console.warn(JSON.stringify({ msg: "turn mint failed", status: res.status }))
    return { ok: false, code: "signal.turn_unavailable", message: `TURN provider answered ${res.status}`, retryable: res.status >= 500 || res.status === 429 }
  }
  const servers = iceServersOf(await res.json().catch(() => null))
  if (servers.length === 0) return { ok: false, code: "signal.turn_unavailable", message: "TURN provider returned no servers", retryable: true }
  return { ok: true, value: { ice_servers: servers, expires_at: now + TURN_TTL_SECONDS * 1000 } }
}

export const turnAsRead = (r: TurnResult): ReadAnswer => (r.ok ? { ok: true, value: r.value, revision: "0" } : { ok: false, code: r.code, message: r.message, retryable: r.retryable })
