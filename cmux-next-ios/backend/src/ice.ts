import type { Env } from "./env.ts"

export const STUN = "stun:stun.cloudflare.com:3478"

export interface IceServer {
  urls: Array<string>
  username?: string
  credential?: string
}

/**
 * Short-lived TURN credentials from the Cloudflare Realtime TURN key
 * (POST /v1/turn/keys/{id}/credentials/generate-ice-servers). Cloudflare STUN is always included,
 * so a missing or failing TURN key still yields a usable (STUN-only) answer with `turn: false`.
 */
export const iceServers = async (env: Env, fetcher: typeof fetch = fetch): Promise<{ iceServers: Array<IceServer>; ttl: number; turn: boolean }> => {
  const ttl = Math.min(Math.max(Number(env.ICE_TTL_SECONDS ?? "3600") || 3600, 300), 172800)
  const out: Array<IceServer> = []
  let turn = false
  if (env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN) {
    try {
      const res = await fetcher(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`, {
        method: "POST",
        headers: { authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
        body: JSON.stringify({ ttl }),
        signal: AbortSignal.timeout(10_000)
      })
      if (res.ok) {
        const body = (await res.json()) as { iceServers?: unknown }
        const list = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : []
        for (const s of list as Array<{ urls?: unknown; username?: unknown; credential?: unknown }>) {
          const urls = (Array.isArray(s.urls) ? s.urls : [s.urls]).filter((u): u is string => typeof u === "string")
          if (!urls.length) continue
          out.push({ urls, ...(typeof s.username === "string" ? { username: s.username } : {}), ...(typeof s.credential === "string" ? { credential: s.credential } : {}) })
          if (urls.some((u) => u.startsWith("turn"))) turn = true
        }
      } else {
        console.log(JSON.stringify({ msg: "turn credentials failed", status: res.status }))
      }
    } catch (e) {
      console.log(JSON.stringify({ msg: "turn credentials error", error: String(e) }))
    }
  }
  if (!out.some((s) => s.urls.includes(STUN))) out.unshift({ urls: [STUN] })
  return { iceServers: out, ttl, turn }
}
