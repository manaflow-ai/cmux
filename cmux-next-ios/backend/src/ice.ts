import type { Env } from "./env.ts"

export const STUN = "stun:stun.cloudflare.com:3478"

export interface IceServer {
  urls: Array<string>
  username?: string
  credential?: string
}

const iceTtl = (env: Env) => Math.min(Math.max(Number(env.ICE_TTL_SECONDS ?? "3600") || 3600, 300), 172800)

const b64 = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes)))

/**
 * Our own TURN relay (coturn `use-auth-secret`, eturnal `credentials: ephemeral`): the TURN REST API scheme
 * (draft-uberti-behave-turn-rest). The username is `<expiry unix seconds>:<label>` and the credential the
 * base64 HMAC-SHA1 of it under the relay's shared secret, so minting is a local computation: no vendor call,
 * no per-byte meter, nothing to cache. `TURN_SELF_URLS` is a comma list of turn:/turns: URLs.
 */
export const selfTurn = async (env: Env, ttl: number, now = Date.now()): Promise<IceServer | undefined> => {
  const urls = (env.TURN_SELF_URLS ?? "").split(",").map((u) => u.trim()).filter((u) => /^turns?:/.test(u))
  if (!urls.length || !env.TURN_SELF_SECRET) return undefined
  const username = `${Math.floor(now / 1000) + ttl}:cmux`
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.TURN_SELF_SECRET), { name: "HMAC", hash: "SHA-1" }, false, ["sign"])
  const credential = b64(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username)))
  return { urls, username, credential }
}

/**
 * Short-lived TURN credentials from our own relay when `TURN_SELF_URLS` and `TURN_SELF_SECRET` are set (Cloudflare
 * is then never called, so its metered TURN costs nothing); otherwise from the Cloudflare Realtime TURN key
 * (POST /v1/turn/keys/{id}/credentials/generate-ice-servers). Cloudflare STUN is always included,
 * so a missing or failing TURN key still yields a usable (STUN-only) answer with `turn: false`.
 */
export const iceServers = async (env: Env, fetcher: typeof fetch = fetch): Promise<{ iceServers: Array<IceServer>; ttl: number; turn: boolean }> => {
  const ttl = iceTtl(env)
  const out: Array<IceServer> = []
  let turn = false
  const own = await selfTurn(env, ttl)
  if (own) {
    out.push(own)
    turn = true
  } else if (env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN) {
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

type IceAnswer = Awaited<ReturnType<typeof iceServers>>
export type CachedIce = { issuedAt: number; usableUntil: number; answer: IceAnswer }
type IceScope = { key: string; entry?: CachedIce; mint?: Promise<IceAnswer> }

const safetyMarginMs = 30_000
// A true cold miss waits for the TURN mint almost as long as the Mac does
// (host.rs ICE_BUDGET, 5 s), so a slow link still gets TURN. Shorter, and a
// lossy-10 cold miss served 94 of 250 phones STUN-only.
const coldWaitMs = 4_500
// A STUN-only answer from a cold miss is kept briefly, so the caller
// refetches and finds the TURN answer the background mint stored.
const coldFallbackTtl = 60
let isolate: IceScope | undefined

const remainingMs = (entry: CachedIce) => entry.issuedAt + entry.answer.ttl * 1000 - Date.now()
const storage = (env: Env, scope: IceScope) => env.TEAM_HUB.get(env.TEAM_HUB.idFromName(scope.key))

async function mint(env: Env, scope: IceScope, ctx: ExecutionContext): Promise<IceAnswer> {
  if (scope.mint) return scope.mint
  const issuedAt = Date.now()
  scope.mint = iceServers(env).then((answer) => {
    if (!answer.turn) return answer
    const entry = { issuedAt, usableUntil: issuedAt + answer.ttl * 1000 - safetyMarginMs, answer }
    scope.entry = entry
    ctx.waitUntil(storage(env, scope).writeIce(entry).catch(() => {
      console.log(JSON.stringify({ msg: "TURN cache write failed" }))
    }))
    return { ...answer, ttl: Math.floor(remainingMs(entry) / 1000) }
  }).finally(() => { scope.mint = undefined })
  return scope.mint
}

function serveCached(env: Env, scope: IceScope, ctx: ExecutionContext): IceAnswer | undefined {
  const entry = scope.entry
  if (!entry || Date.now() >= entry.usableUntil) return undefined
  const left = remainingMs(entry)
  if (left <= (entry.answer.ttl * 1000) / 2) ctx.waitUntil(mint(env, scope, ctx))
  return { ...entry.answer, ttl: Math.floor(left / 1000) }
}

async function loadShared(env: Env, scope: IceScope, ctx: ExecutionContext): Promise<IceAnswer> {
  const stored = await storage(env, scope).readIce().catch(() => {
    console.log(JSON.stringify({ msg: "TURN cache read failed" }))
    return undefined
  })
  if (stored && (!scope.entry || stored.issuedAt > scope.entry.issuedAt)) scope.entry = stored
  return serveCached(env, scope, ctx) ?? mint(env, scope, ctx)
}

export async function cachedIceServers(env: Env, ctx: ExecutionContext): Promise<IceAnswer> {
  // Our own relay's credentials are an HMAC away: nothing to cache or wait for.
  if ((env.TURN_SELF_URLS && env.TURN_SELF_SECRET) || !env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return iceServers(env)
  // A TURN mint uses the Worker's key and TTL, irrespective of caller or team.
  // This reserved object in the existing binding is accessible on every ingress.
  const key = JSON.stringify(["turn-cache-v1", env.ENVIRONMENT, env.TURN_KEY_ID, iceTtl(env)])
  if (isolate?.key !== key) isolate = { key }
  const hit = serveCached(env, isolate, ctx)
  if (hit) return hit

  // A slow but successful mint can still populate both caches after this
  // response. Only the foreground wait counts against the Mac's 5 s budget.
  const pending = loadShared(env, isolate, ctx)
  ctx.waitUntil(pending)
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([pending, new Promise<IceAnswer>((resolve) => {
      timer = setTimeout(() => resolve({ iceServers: [{ urls: [STUN] }], turn: false, ttl: coldFallbackTtl }), coldWaitMs)
    })])
  } finally {
    clearTimeout(timer)
  }
}
