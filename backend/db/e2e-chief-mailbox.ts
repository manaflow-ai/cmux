/**
 * End-to-end check of the Mac Chief mailbox (cmux-prompts logs/iphone-chief-DESIGN.md, a450)
 * against a deployed environment (default staging), over the real Worker sockets:
 *
 * Stack sign-in (the phone's session) -> install.register + install JWT (the Mac) -> host.enroll
 * -> the Mac publishes its Chief copy on host:<h>/chief -> the Mac goes offline -> the phone reads
 * the copy (history) and sends two messages, one twice (op.queued, same entry) -> the Mac comes
 * back and gets each kept message once, in order -> it settles them -> the phone sees
 * mailbox.settled -> a second reconnect gets nothing -> cleanup (host.remove, install.revoke).
 *
 *   bun db/e2e-chief-mailbox.ts [--env staging|development|production]
 *
 * Reads the Stack dev test account from ~/.secrets; prints ids only, never secrets. Production
 * uses the same account only when CMUX_E2E_PRODUCTION_ACCOUNT_FILE names a file with
 * CMUX_E2E_EMAIL and CMUX_E2E_PASSWORD for the production Stack project.
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const envName = process.argv.includes("--env") ? process.argv[process.argv.indexOf("--env") + 1]! : "staging"
const API = envName === "production" ? "https://cloud-api.cmux.dev" : envName === "staging" ? "https://cloud-api-staging.cmux.dev" : `https://cmux-api-${envName}.debussy.workers.dev`
const readEnv = (file: string) =>
  Object.fromEntries(
    readFileSync(file.startsWith("/") ? file : join(homedir(), ".secrets", file), "utf8")
      .split("\n")
      .filter((l) => l.includes("=") && !l.startsWith("#"))
      .map((l) => [l.slice(0, l.indexOf("=")).replace(/^export /, ""), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")])
  ) as Record<string, string>

const step = (s: string) => console.log(`- ${s}`)
const fail = (s: string): never => {
  console.error(`FAIL: ${s}`)
  process.exit(1)
}
const expect = (cond: unknown, what: string) => {
  if (!cond) throw new Error(what)
}

const account = (() => {
  if (envName !== "production") {
    const dev = readEnv("cmuxterm-dev.env")
    return { project: dev.NEXT_PUBLIC_STACK_PROJECT_ID!, key: dev.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY!, email: dev.CMUX_DOGFOOD_STACK_EMAIL!, password: dev.CMUX_DOGFOOD_STACK_PASSWORD! }
  }
  const file = process.env.CMUX_E2E_PRODUCTION_ACCOUNT_FILE ?? fail("production needs CMUX_E2E_PRODUCTION_ACCOUNT_FILE")
  const p = readEnv(file)
  return { project: p.STACK_PROJECT_ID!, key: p.STACK_PUBLISHABLE_CLIENT_KEY!, email: p.CMUX_E2E_EMAIL!, password: p.CMUX_E2E_PASSWORD! }
})()

const signIn = async () => {
  const res = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", {
    method: "POST",
    headers: { "content-type": "application/json", "x-stack-project-id": account.project, "x-stack-publishable-client-key": account.key, "x-stack-access-type": "client" },
    body: JSON.stringify({ email: account.email, password: account.password })
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

/** One `cmux.wire.v1` socket on the host's replica. */
const socket = async (host: string, token: string) => {
  const ws = new WebSocket(`${API.replace("https", "wss")}/v1/wire/host/${host}`, { protocols: ["cmux.wire.v1"], headers: { authorization: `Bearer ${token}` } } as unknown as string[])
  const frames: Array<any> = []
  let wake: (() => void) | undefined
  let closed = false
  ws.onmessage = (e) => {
    frames.push(JSON.parse(String(e.data)))
    wake?.()
  }
  ws.onclose = () => {
    closed = true
    wake?.()
  }
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve()
    ws.onerror = () => reject(new Error("websocket error"))
  })
  const until = async (match: (f: any) => boolean, what: string, from = 0): Promise<number> => {
    const deadline = Date.now() + 20_000
    for (;;) {
      const i = frames.findIndex((f, n) => n >= from && match(f))
      if (i >= 0) return i
      if (closed) throw new Error(`socket closed waiting for ${what}`)
      if (Date.now() > deadline) throw new Error(`timeout waiting for ${what}: ${JSON.stringify(frames.slice(-5))}`)
      await new Promise<void>((r) => {
        wake = r
        setTimeout(r, 500)
      })
    }
  }
  const settle = (ms: number) => new Promise((r) => setTimeout(r, ms))
  return { ws, frames, until, settle, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}

const session = await signIn()
const ensure = await op(session, "user.ensure", {})
expect(ensure.json.ok, `user.ensure: ${JSON.stringify(ensure.json)}`)
const user = ensure.json.value.id as string
step(`phone: signed in as ${user} (${envName}, ${API})`)

const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
const reg = await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "e2e mac (chief mailbox)", device_name: "e2e mac", platform: "macos" })
expect(reg.json.ok, `install.register: ${JSON.stringify(reg.json)}`)
const install = reg.json.value.id as string
const ch = await call("/v1/auth/challenge", undefined, { user, install })
const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
const tok = await call("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig) })
expect(tok.status === 200, `token ${tok.status}`)
const mac = tok.json.access_token as string
const enrolled = await op(mac, "host.enroll", { name: "e2e mac (chief mailbox)", platform: "macos" })
expect(enrolled.json.ok, `host.enroll ${JSON.stringify(enrolled.json)}`)
const host = enrolled.json.value.id as string
const chief = `host:${host}/chief`
step(`mac: install ${install}, host ${host}`)

let cleanupDone = false
const cleanup = async () => {
  if (cleanupDone) return
  cleanupDone = true
  await op(session, "host.remove", { host })
  await op(session, "install.revoke", { install })
  step("cleanup: host removed, install revoked")
}

try {
  // The Mac publishes its Chief copy, then goes offline (asleep).
  const pub = await socket(host, mac)
  await pub.until((f) => f.t === "welcome" && f.role === "publisher", "publisher welcome")
  const state = {
    conversation: { id: "conv_e2e", title: "Chief", participants: [{ id: "user_local", kind: "human", display_name: "You" }, { id: "agent_mux", kind: "agent", display_name: "Chief", agent_class: "mux" }], read_cursors: {}, created_at: new Date().toISOString() },
    messages: [{ id: "m1", conversation: "conv_e2e", seq: 1, client_msg_id: "c1", author: "agent_mux", parts: [{ type: "text", text: "hello from the Mac" }], created_at: new Date().toISOString() }]
  }
  pub.send({ t: "publish", stream: chief, snapshot: { t: "snapshot", stream: chief, seq: 1, state, decided: [] } })
  await pub.settle(500)
  pub.ws.close(1000, "asleep")
  step("mac: published its Chief copy, then went offline")

  // The phone: offline status, the copy, then two messages (one sent twice).
  const phone = await socket(host, session)
  await phone.until((f) => f.t === "welcome" && f.role === "reader" && f.owner.status === "offline", "offline welcome")
  phone.send({ t: "subscribe", stream: chief })
  const snap = await phone.until((f) => f.t === "snapshot" && f.stream === chief, "the copy")
  expect(JSON.stringify(phone.frames[snap].state).includes("hello from the Mac"), "the copy carries the Mac's history")
  step("phone: Mac offline; read the Chief history from the cloud copy")
  const send = (key: string, text: string) => phone.send({ t: "op", stream: chief, op: "conversation.message.send", params: { text }, idempotency_key: key, origin: "user" })
  send("e2e-1", "first from the phone")
  send("e2e-2", "second from the phone")
  send("e2e-1", "first from the phone")
  await phone.until((f) => f.t === "op.queued" && f.idempotency_key === "e2e-2" && f.position === 2, "second queued")
  // The resend's answer comes after the others.
  await phone.until(() => phone.frames.filter((f) => f.t === "op.queued").length === 3, "the resend answered")
  const queued = phone.frames.filter((f) => f.t === "op.queued").map((f) => `${f.idempotency_key}@${f.position}`)
  expect(queued.join(",") === "e2e-1@1,e2e-2@2,e2e-1@1", `queued ${queued}`)
  step(`phone: sent 3 (one resend): op.queued ${queued.join(", ")}`)
  phone.ws.close(1000, "pocket")

  // The Mac is back: each kept message once, in order, with the phone's principal.
  const back = await socket(host, mac)
  await back.until((f) => f.t === "welcome", "publisher welcome again")
  const a = await back.until((f) => f.t === "op" && f.to === "mailbox", "first delivery")
  const b = await back.until((f) => f.t === "op" && f.to === "mailbox", "second delivery", a + 1)
  await back.settle(1500)
  const ops = back.frames.filter((f) => f.t === "op")
  expect(ops.length === 2, `delivered ${ops.length} ops`)
  expect(back.frames[a].idempotency_key === "e2e-1" && back.frames[b].idempotency_key === "e2e-2", "in order")
  expect(back.frames[a].principal?.user === user, "with the phone's principal")
  step(`mac: back online; got ${ops.map((f) => `${f.idempotency_key} "${f.params.text}"`).join(", ")} (once each, in order)`)

  const watcher = await socket(host, session)
  watcher.send({ t: "subscribe", stream: chief })
  await watcher.until((f) => f.t === "owner.status" && f.status === "online", "online status")
  for (const [key, seq] of [["e2e-1", 2], ["e2e-2", 3]] as const) back.send({ t: "request-settled", to: "mailbox", tx: `tx-${seq}`, idempotency_key: key, stream: chief, sequence: seq, ok: true })
  await watcher.until((f) => f.t === "mailbox.settled" && f.idempotency_key === "e2e-2", "settled")
  step("phone: saw mailbox.settled for both")
  back.ws.close(1000, "restart")

  const third = await socket(host, mac)
  await third.until((f) => f.t === "welcome", "third welcome")
  await third.settle(1500)
  expect(!third.frames.some((f) => f.t === "op"), "nothing delivered twice")
  step("mac: reconnect again: nothing delivered twice")
  third.ws.close(1000, "done")
  watcher.ws.close(1000, "done")
  await cleanup()
  console.log(`OK: chief mailbox end-to-end ${envName}`)
  process.exit(0)
} catch (error) {
  await cleanup()
  fail(String(error))
}
