#!/usr/bin/env bun
/**
 * Live smoke test of a deployed cmux-mobile-api (PROTOCOL.md v1). Never prints tokens.
 *
 *   CMUX_MOBILE_TOKEN_FILE=/path/to/token bun scripts/smoke.ts            # a Stack access token in a 0600 file
 *   CMUX_MOBILE_TEAM=personal ...                                         # use the caller's personal space
 *   STACK_EMAIL=... STACK_PASSWORD=... bun scripts/smoke.ts       # password sign-in on the dev project
 *
 * Env: CMUX_MOBILE_BASE_URL (default the dev Worker), STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY (dev defaults).
 */
import { readFileSync } from "node:fs"

const BASE = process.env.CMUX_MOBILE_BASE_URL ?? "https://cmux-mobile-api-dev.debussy.workers.dev"
const PROJECT = process.env.STACK_PROJECT_ID ?? "454ecd03-1db2-4050-845e-4ce5b0cd9895"
const PCK = process.env.STACK_PUBLISHABLE_CLIENT_KEY ?? "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
const stackHeaders = (extra: Record<string, string> = {}) => ({ "content-type": "application/json", "x-stack-project-id": PROJECT, "x-stack-access-type": "client", ...(PCK ? { "x-stack-publishable-client-key": PCK } : {}), ...extra })

let failures = 0
const check = (name: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`)
  if (!ok) failures++
}

const token = await (async () => {
  if (process.env.CMUX_MOBILE_TOKEN_FILE) return readFileSync(process.env.CMUX_MOBILE_TOKEN_FILE, "utf8").trim()
  if (process.env.STACK_EMAIL && process.env.STACK_PASSWORD) {
    const r = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", { method: "POST", headers: stackHeaders(), body: JSON.stringify({ email: process.env.STACK_EMAIL, password: process.env.STACK_PASSWORD }) })
    if (!r.ok) throw new Error(`Stack sign-in returned ${r.status}`)
    return ((await r.json()) as { access_token: string }).access_token
  }
  throw new Error("set CMUX_MOBILE_TOKEN_FILE or STACK_EMAIL/STACK_PASSWORD")
})()

const api = async (method: string, path: string, body?: unknown, auth = true) => {
  const r = await fetch(`${BASE}${path}`, { method, headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: r.status, json: (await r.json().catch(() => null)) as any }
}

// 1. health and auth
const health = await api("GET", "/v1/health", undefined, false)
check("health", health.status === 200 && health.json?.ok === true, `version ${health.json?.version}`)
check("rejects missing token", (await api("GET", "/v1/ice", undefined, false)).status === 401)
check("accepts the token's project", (health.json?.stackProjects ?? []).includes(PROJECT), `${(health.json?.stackProjects ?? []).length} projects`)

// 2. the team: CMUX_MOBILE_TEAM=personal uses the caller's personal space, else the first Stack team
const sub = JSON.parse(Buffer.from(token.split(".")[1]!, "base64url").toString()).sub as string
const teamId = process.env.CMUX_MOBILE_TEAM === "personal"
  ? `personal-${sub}`
  : (((await (await fetch("https://api.stack-auth.com/api/v1/teams?user_id=me", { headers: stackHeaders({ "x-stack-access-token": token }) })).json()) as { items?: Array<{ id: string }> }).items ?? [])[0]?.id
check("team", !!teamId, teamId?.startsWith("personal-") ? "personal space" : "stack team")
if (!teamId) process.exit(1)

// 3. ICE
const ice = await api("GET", "/v1/ice")
const urls: Array<string> = (ice.json?.iceServers ?? []).flatMap((s: any) => s.urls)
check("ice stun", ice.status === 200 && urls.includes("stun:stun.cloudflare.com:3478"))
check("ice turn", urls.some((u) => u.startsWith("turn")) && ice.json?.turn === true, `${urls.filter((u) => u.startsWith("turn")).length} turn urls, ttl ${ice.json?.ttl}, turn flag ${ice.json?.turn}`)

// 4. devices, macs, prefs
const macId = crypto.randomUUID()
const phoneId = crypto.randomUUID()
const mac = await api("POST", "/v1/devices", { deviceId: macId, kind: "mac", name: "smoke-mac", teamId })
const phone = await api("POST", "/v1/devices", { deviceId: phoneId, kind: "phone", name: "smoke-phone", teamId })
check("device upsert", mac.status === 200 && phone.status === 200 && mac.json.device.deviceId === macId, `${mac.status}/${phone.status}`)
const rename = await api("POST", "/v1/devices", { deviceId: macId, kind: "mac", name: "smoke-mac-renamed", teamId })
check("device rename", rename.json?.device?.name === "smoke-mac-renamed" && rename.json.device.createdAt === mac.json.device.createdAt)
const macs = await api("GET", `/v1/teams/${teamId}/macs`)
check("team macs", macs.status === 200 && macs.json.macs.some((m: any) => m.deviceId === macId && m.online === false))
const mine = await api("GET", "/v1/me/macs")
check("my macs in every space", mine.status === 200 && mine.json.macs.some((m: any) => m.deviceId === macId && m.teamId === teamId) && !mine.json.macs.some((m: any) => m.deviceId === phoneId), `${mine.json?.macs?.length ?? 0} macs`)
const forged = await fetch(`${BASE}/v1/me/macs`, { headers: { authorization: `Bearer ${token.slice(0, -4)}AAAA` } })
check("401 names the reason", forged.status === 401 && /\((bad_signature|malformed)\)$/.test(((await forged.json()) as any)?.error?.message ?? ""))
const color = `#${Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, "0").toUpperCase()}`
const put = await api("PUT", `/v1/teams/${teamId}/prefs`, { color, emoji: "🧪" })
const got = await api("GET", `/v1/teams/${teamId}/prefs`)
check("prefs", put.status === 200 && got.json?.color === color && got.json?.emoji === "🧪")
// Follows the "🧪" PUT above (an icon is set); leaves the test team at emoji "🧪" and transparent false.
const clear = await api("PUT", `/v1/teams/${teamId}/prefs`, { transparent: true })
const filled = await api("PUT", `/v1/teams/${teamId}/prefs`, { emoji: "" })
const bare = await api("PUT", `/v1/teams/${teamId}/prefs`, { transparent: true })
const back = await api("PUT", `/v1/teams/${teamId}/prefs`, { emoji: "🧪" })
check("prefs transparent", clear.json?.transparent === true && clear.json?.color === color && filled.json?.transparent === false && filled.json?.color === color && bare.status === 400 && back.json?.transparent === false)
if (teamId.startsWith("personal-")) check("personal invite refused", (await api("POST", `/v1/teams/${teamId}/invites`, { email: "x@example.com" })).status === 400)
check("other personal space refused", (await api("GET", "/v1/teams/personal-someone-else/macs")).status === 403)
check("foreign team refused", (await api("GET", `/v1/teams/00000000-0000-0000-0000-000000000000/macs`)).status === 403)

// 5. two-client signaling
const wsUrl = `${BASE.replace(/^http/, "ws")}/v1/teams/${teamId}/signal`
const open = (deviceId: string) =>
  new Promise<{ ws: WebSocket; frames: Array<any>; bins: Array<Uint8Array>; wait: (p: (f: any) => boolean, ms?: number) => Promise<any> }>((resolve, reject) => {
    const ws = new WebSocket(`${wsUrl}?deviceId=${deviceId}`, ["cmux-mobile.v1", `bearer.${token}`])
    ws.binaryType = "arraybuffer"
    const frames: Array<any> = []
    const bins: Array<Uint8Array> = []
    const waiters: Array<() => void> = []
    ws.addEventListener("message", (e: MessageEvent) => {
      if (typeof e.data === "string") frames.push(JSON.parse(e.data))
      else bins.push(new Uint8Array(e.data as ArrayBuffer))
      waiters.splice(0).forEach((w) => w())
    })
    const wait = async (p: (f: any) => boolean, ms = 5000) => {
      const end = Date.now() + ms
      for (;;) {
        const hit = frames.find(p)
        if (hit) return hit
        if (Date.now() > end) return undefined
        await new Promise<void>((r) => {
          waiters.push(r)
          setTimeout(r, 100)
        })
      }
    }
    ws.addEventListener("open", () => resolve({ ws, frames, bins, wait }))
    ws.addEventListener("error", () => reject(new Error(`websocket ${deviceId.slice(0, 8)} failed`)))
  })

const m = await open(macId)
check("mac hello", !!(await m.wait((f) => f.type === "hello")))
const p = await open(phoneId)
const hello = await p.wait((f) => f.type === "hello")
check("phone hello lists mac online", !!hello?.macs?.some((x: any) => x.deviceId === macId && x.online), `subprotocol ${p.ws.protocol}`)

const sessionId = crypto.randomUUID()
p.ws.send(JSON.stringify({ type: "signal", to: macId, from: phoneId, sessionId, payload: { kind: "webrtc-offer", sdp: "v=0 smoke" } }))
const offer = await m.wait((f) => f.type === "signal" && f.sessionId === sessionId)
check("offer phone->mac", offer?.from === phoneId && offer?.payload?.sdp === "v=0 smoke")
check("offer carries fromUserId", typeof offer?.fromUserId === "string" && offer.fromUserId.length > 0)
m.ws.send(JSON.stringify({ type: "signal", to: phoneId, from: macId, sessionId, payload: { kind: "webrtc-answer", sdp: "v=0 answer" } }))
const answer = await p.wait((f) => f.type === "signal" && f.sessionId === sessionId)
check("answer mac->phone", answer?.from === macId && answer?.payload?.kind === "webrtc-answer")

const hex = (id: string) => Uint8Array.from(id.replace(/-/g, "").match(/../g)!.map((h) => parseInt(h, 16)))
const frame = new Uint8Array(36)
frame.set(hex(sessionId), 0)
frame.set(hex(macId), 16)
frame.set([9, 8, 7, 6], 32)
p.ws.send(frame)
// Relay frames are retired (0.9.0): dropped, one relay_retired error naming the session.
const retired = await p.wait((f) => f.type === "error" && f.code === "relay_retired")
await new Promise((r) => setTimeout(r, 500))
check("relay frame refused", retired?.sessionId === sessionId && m.bins.length === 0)

p.ws.send(JSON.stringify({ type: "signal", to: phoneId, from: phoneId, sessionId: crypto.randomUUID(), payload: { kind: "bye", reason: "x" } }))
check("self-signal refused", (await p.wait((f) => f.type === "error" && f.code === "not_owner"))?.code === "not_owner")

m.ws.close(1000, "smoke done")
const off = await p.wait((f) => f.type === "presence" && f.mac?.deviceId === macId && f.mac.online === false)
check("presence offline", !!off, off?.mac?.lastSeenAt ? "lastSeenAt set" : "")

// 6. 0.7.0: device list, push registration, notify, device removal (also cleans up the smoke devices)
// The APNs key is production-only and scoped to the TestFlight app, so the fake token goes there:
// APNs answers BadDeviceToken and the Worker drops it (a sandbox token fails at the key instead).
const topic = process.env.CMUX_MOBILE_PUSH_TOPIC ?? "dev.cmux.app.internal"
const pushEnvironment = process.env.CMUX_MOBILE_PUSH_ENVIRONMENT ?? "production"
const fakeToken = "00".repeat(32)
const reg = await api("PUT", `/v1/devices/${phoneId}/push`, { token: fakeToken, environment: pushEnvironment, topic, kinds: ["question"] })
check("push register", reg.status === 200 && reg.json?.push?.kinds?.[0] === "question", `${reg.status}`)
const listed = await api("GET", "/v1/me/devices")
const lp = listed.json?.devices?.find((d: any) => d.deviceId === phoneId)
check("me/devices", listed.status === 200 && lp?.push === true && listed.json.devices.some((d: any) => d.deviceId === macId && d.kind === "mac"), `${listed.json?.devices?.length ?? 0} devices`)
const notify = await api("POST", `/v1/devices/${macId}/notify`, { eventId: `smoke-${Date.now()}`, kind: "question", agent: "Smoke", place: "smoke" })
// A fake token: APNs (when configured) refuses it and the Worker drops it.
check("notify", notify.status === 200 && typeof notify.json?.configured === "boolean" && (!notify.json.configured || notify.json.dropped === 1), `configured ${notify.json?.configured}, sent ${notify.json?.sent}, failed ${notify.json?.failed}, dropped ${notify.json?.dropped}`)
check("notify from a phone refused", (await api("POST", `/v1/devices/${phoneId}/notify`, { eventId: "x", kind: "question" })).status === 403)
const m2 = await open(macId)
await m2.wait((f) => f.type === "hello")
await p.wait((f) => f.type === "presence" && f.mac?.deviceId === macId && f.mac.online === true)
let closeCode = 0
m2.ws.addEventListener("close", (e: CloseEvent) => {
  closeCode = e.code
})
const del = await api("DELETE", `/v1/devices/${macId}`)
check("delete mac", del.status === 200 && del.json?.deleted === true)
const removed = await p.wait((f) => f.type === "presence" && f.mac?.deviceId === macId && f.mac.removed === true)
const closeEnd = Date.now() + 5000
while (!closeCode && Date.now() < closeEnd) await new Promise((r) => setTimeout(r, 50))
check("removal broadcast and eviction", !!removed && closeCode === 4002, `close ${closeCode}`)
check("deleted mac gone", !(await api("GET", "/v1/me/macs")).json?.macs?.some((x: any) => x.deviceId === macId))
check("delete again is 404", (await api("DELETE", `/v1/devices/${macId}`)).status === 404)
p.ws.close(1000, "smoke done")
check("delete phone", (await api("DELETE", `/v1/devices/${phoneId}`)).status === 200)

console.log(failures ? `${failures} check(s) failed` : "all checks passed")
process.exit(failures ? 1 : 0)
