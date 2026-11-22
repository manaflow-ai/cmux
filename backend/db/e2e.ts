/**
 * End-to-end check against a deployed environment (default staging):
 * Stack sign-in -> user.ensure -> install.register (idempotent) -> signed
 * challenge -> install JWT -> op over the wire with echo (event, result,
 * request-settled) -> host.enroll -> team.directory -> revoke -> token refused
 * -> PlanetScale projection rows present.
 *
 *   bun db/e2e.ts [--env staging|development]
 *
 * Reads the Stack dev test account and the PlanetScale app role from ~/.secrets;
 * prints ids and transaction tags only, never secrets.
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import pg from "pg"

const envName = process.argv.includes("--env") ? process.argv[process.argv.indexOf("--env") + 1]! : "staging"
const API = `https://cmux-api-${envName}.debussy.workers.dev`
const readEnv = (file: string) =>
  Object.fromEntries(
    readFileSync(join(homedir(), ".secrets", file), "utf8")
      .split("\n")
      .filter((l) => l.includes("=") && !l.startsWith("#"))
      .map((l) => [l.slice(0, l.indexOf("=")).replace(/^export /, ""), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")])
  ) as Record<string, string>

const dev = readEnv("cmuxterm-dev.env")
const projectId = dev.NEXT_PUBLIC_STACK_PROJECT_ID!
const step = (s: string) => console.log(`- ${s}`)
const fail = (s: string): never => {
  console.error(`FAIL: ${s}`)
  process.exit(1)
}
const expect = (cond: unknown, what: string) => (cond ? undefined : fail(what))

const signIn = async () => {
  const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-stack-project-id": projectId,
      "x-stack-publishable-client-key": dev.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY!,
      "x-stack-access-type": "client"
    },
    body: JSON.stringify({ email: dev.CMUX_DOGFOOD_STACK_EMAIL, password: dev.CMUX_DOGFOOD_STACK_PASSWORD })
  })
  if (!res.ok) fail(`Stack sign-in ${res.status}`)
  return ((await res.json()) as { access_token: string }).access_token
}

const call = async (path: string, token: string | undefined, body?: unknown) => {
  const res = await fetch(`${API}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json().catch(() => ({}))) as any }
}
const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "cli" })
const b64u = (buf: ArrayBuffer) => Buffer.from(buf).toString("base64url")

const session = await signIn()
step("Stack dev sign-in ok")

const ensure = await op(session, "user.ensure", {})
expect(ensure.json.ok, `user.ensure: ${JSON.stringify(ensure.json)}`)
const user = ensure.json.value.id as string
step(`user.ensure -> ${user} (team ${ensure.json.value.personal_team}) tx=${ensure.json.transaction}`)

const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
const params = { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "cli", name: `e2e ${new Date().toISOString().slice(0, 16)}`, device_name: "e2e runner", platform: "macos" }
const key = `e2e-register-${crypto.randomUUID()}`
const reg = await op(session, "install.register", params, key)
expect(reg.json.ok, `install.register: ${JSON.stringify(reg.json)}`)
const install = reg.json.value.id as string
const again = await op(session, "install.register", params, key)
expect(again.json.replayed && again.json.transaction === reg.json.transaction && again.json.value.id === install, "replay returns the original result")
step(`install.register -> ${install} seq=${reg.json.sequence} tx=${reg.json.transaction}; replay with same key: replayed=true, same tx`)

const ch = await call("/v1/auth/challenge", undefined, { user, install })
expect(ch.status === 200, `challenge ${ch.status}`)
const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
expect(tok.status === 200, `token ${tok.status} ${JSON.stringify(tok.json)}`)
const jwt = tok.json.access_token as string
step(`signed challenge -> install JWT (grant ${tok.json.grant}, expires ${new Date(tok.json.expires_at).toISOString()})`)
const reuse = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
expect(reuse.status === 403, "a used nonce is refused")
step("reused challenge nonce refused (403)")

// Wire: subscribe, then an op from the install; expect event -> result -> request-settled with one tx.
const ws = new WebSocket(`${API.replace("https", "wss")}/v1/wire/user`, ["cmux.wire.v1", `bearer.${jwt}`])
const frames: Array<any> = []
let wake: (() => void) | undefined
ws.onmessage = (e) => {
  frames.push(JSON.parse(String(e.data)))
  wake?.()
}
const until = async (pred: () => boolean, what: string) => {
  const deadline = Date.now() + 15_000
  while (!pred()) {
    if (Date.now() > deadline) fail(`timeout waiting for ${what}`)
    await new Promise<void>((r) => {
      wake = r
      setTimeout(r, 1000)
    })
  }
}
await new Promise<void>((resolve, reject) => {
  ws.onopen = () => resolve()
  ws.onerror = () => reject(new Error("websocket error"))
})
ws.send(JSON.stringify({ t: "subscribe", stream: `user:${user}`, pending: [] }))
await until(() => frames.some((f) => f.t === "snapshot"), "snapshot")
ws.send(JSON.stringify({ t: "op", op: "install.rename", params: { install, name: "e2e renamed over wire" }, idempotency_key: "wire-rename-1", origin: "cli" }))
await until(() => frames.some((f) => f.t === "request-settled"), "request-settled")
const order = frames.filter((f) => ["event", "result", "request-settled"].includes(f.t))
expect(order.map((f) => f.t).join(",") === "event,result,request-settled", `order ${order.map((f) => f.t)}`)
expect(order[0].tx === order[2].tx && order[2].sequence === order[0].seq, "event tx and settled sequence match")
step(`wire op install.rename: event seq=${order[0].seq} tx=${order[0].tx} actor=${order[0].actor.install}, then result, then request-settled{sequence=${order[2].sequence}}`)
ws.close()

const host = await op(jwt, "host.enroll", { name: "e2e host", platform: "macos" })
expect(host.json.ok, `host.enroll ${JSON.stringify(host.json)}`)
const dir = await call("/v1/read", session, { op: "team.directory", params: {} })
expect(dir.json.value.hosts.some((h: any) => h.id === host.json.value.id), "host in directory")
step(`host.enroll -> ${host.json.value.id}; team.directory lists ${dir.json.value.members.length} member(s), ${dir.json.value.hosts.length} host(s)`)

const removed = await op(session, "host.remove", { host: host.json.value.id })
expect(removed.json.ok, "host.remove")
const revoke = await op(session, "install.revoke", { install })
expect(revoke.json.ok, "install.revoke")
const after = await call("/v1/auth/challenge", undefined, { user, install })
expect(after.status === 403, "challenge after revoke is refused")
const stale = await op(jwt, "install.rename", { install, name: "after revoke" })
expect(stale.json.error?.code === "auth.forbidden", "existing token refused after revoke")
step("install.revoke: new challenge refused (403), existing JWT op refused (auth.forbidden)")

// Projection: outbox drained by alarm into PlanetScale cmux-next.
const ps = readEnv(`cmux-next-planetscale-${envName}.env`)
const client = new pg.Client({ connectionString: ps.CMUX_NEXT_PG_APP_URL })
await client.connect()
let row: any
for (let i = 0; i < 20; i++) {
  row = (await client.query("SELECT i.id, i.name, i.revoked_at IS NOT NULL AS revoked, u.id AS user_id FROM installs i JOIN users u ON u.id = i.user_id WHERE i.id = $1", [install])).rows[0]
  if (row?.revoked) break
  await new Promise((r) => setTimeout(r, 500 * (i + 1)))
}
await client.end()
expect(row?.revoked && row.user_id === user, `projection row ${JSON.stringify(row)}`)
step(`PlanetScale cmux-next/${envName} projection: installs row ${row.id} revoked=${row.revoked}, name="${row.name}"`)
console.log(`OK: end-to-end ${envName}`)
