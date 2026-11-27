/**
 * Tenant isolation against a deployed staging API (plans/cmux-next/tenant-isolation-DESIGN.md section 6). Two throwaway accounts
 * (Stack sign-up with the project's publishable client key, e-mail `tenant-iso-<run>-<a|b>@example.test`, never a real person) are
 * made, tenant A creates real objects, and tenant B then calls the catalog's operations with A's ids and with ids that do not exist.
 * Pass: no A marker in a B reply, A's view unchanged, A's ids answer exactly like unknown ids, forged and tampered tokens get 401,
 * a revoked install stops at once. Operations that spend money or start machines are not called (SKIP below; the hermetic suite
 * covers them with a fake provider).
 *
 *   bun backend/scripts/tenant-isolation-staging.ts [--env staging] [--report PATH]
 *
 * Reads ~/.secrets/cmuxterm-dev.env (project id, publishable client key; STACK_SECRET_SERVER_KEY only to delete the two users at the
 * end). Prints ids and verdicts, never a token or key. Leaves nothing behind except the two (deleted) Stack users and their empty
 * staging Durable Objects.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { catalogOps, idsIn, sampleParams, shape, stable } from "../apps/api/test/setup/tenant-sample.ts"

const arg = (n: string, d: string) => (process.argv.includes(n) ? process.argv[process.argv.indexOf(n) + 1]! : d)
const envName = arg("--env", "staging")
const API = envName === "staging" ? "https://cmux-api-staging.debussy.workers.dev" : (() => { throw new Error(`env ${envName} is not allowed: this runner never touches production`) })()
const reportPath = arg("--report", "")
const secrets = Object.fromEntries(readFileSync(join(homedir(), ".secrets", "cmuxterm-dev.env"), "utf8").split("\n").filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).replace(/^export /, ""), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")])) as Record<string, string>
const projectId = secrets.NEXT_PUBLIC_STACK_PROJECT_ID!
const clientKey = secrets.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY!
const run = crypto.randomUUID().slice(0, 8)
const SKIP = /^(team_vm\.|cloud\.|automation\.(run|deploy)$|mail\.send$|slack\.|github\.|linear\.|calendar\.event|integration\.connect$|sso\.|domain\.|push\.|user\.text_confirm\.lower|tunnel\.|team\.enrollment_token\.create$)/
const b64u = (b: ArrayBuffer) => Buffer.from(b).toString("base64url")

interface Reply { status: number; body: any; code: string | undefined; raw: string }
const http = async (method: string, path: string, token: string | undefined, body?: unknown): Promise<Reply> => {
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(`${API}${path}`, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    const raw = await res.text()
    if (res.status === 429 || res.status === 503) { await new Promise((r) => setTimeout(r, 1500 * (attempt + 1))); continue }
    let parsed: any = null
    try { parsed = JSON.parse(raw) } catch {}
    return { status: res.status, body: parsed, code: parsed?.error?.code ?? (parsed?.ok === false ? parsed?.error?.code : undefined), raw }
  }
  return { status: 429, body: null, code: "rate_limited", raw: "rate limited" }
}
const callOp = (t: string | undefined, op: string, params: unknown) => http("POST", "/v1/ops", t, { op, params, idempotency_key: crypto.randomUUID(), origin: "cli" })
const callRead = (t: string | undefined, op: string, params: unknown) => http("POST", "/v1/read", t, { op, params })
const call = (cls: string, t: string | undefined, op: string, params: unknown) => (cls === "read" ? callRead(t, op, params) : callOp(t, op, params))
const ok = (r: Reply) => r.status === 200 && r.code === undefined && r.body?.ok !== false

interface Tenant { tag: string; email: string; stackUser: string; session: string; user: string; team: string; install: string; installToken: string; keyPair: CryptoKeyPair; canary: string }
const stackHeaders = { "content-type": "application/json", "x-stack-project-id": projectId, "x-stack-publishable-client-key": clientKey, "x-stack-access-type": "client" }
const mint = async (t: { user: string; install: string; keyPair: CryptoKeyPair }) => {
  const ch = await http("POST", "/v1/auth/challenge", undefined, { user: t.user, install: t.install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, t.keyPair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await http("POST", "/v1/auth/token", undefined, { user: t.user, install: t.install, nonce: ch.body.nonce, signature: b64u(sig) })
  return tok.status === 200 ? (tok.body.access_token as string) : undefined
}
const makeTenant = async (tag: string): Promise<Tenant> => {
  const email = `tenant-iso-${run}-${tag}@example.test`
  const password = `Iso-${crypto.randomUUID()}!`
  const up = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-up", { method: "POST", headers: stackHeaders, body: JSON.stringify({ email, password }) })
  if (!up.ok) throw new Error(`Stack sign-up ${tag}: ${up.status}`)
  const j = (await up.json()) as { access_token: string; user_id: string }
  const ensured = await callOp(j.access_token, "user.ensure", {})
  if (!ok(ensured)) throw new Error(`user.ensure ${tag}: ${ensured.raw.slice(0, 200)}`)
  const keyPair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", keyPair.publicKey)) as JsonWebKey
  const canary = `CANARY-${tag.toUpperCase()}-${run}`
  const reg = await callOp(j.access_token, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "cli", name: `${canary} install`, device_name: `${canary} device`, platform: "macos" })
  if (!ok(reg)) throw new Error(`install.register ${tag}: ${reg.raw.slice(0, 200)}`)
  const t = { user: ensured.body.value.id as string, install: reg.body.value.id as string, keyPair }
  const installToken = await mint(t)
  if (!installToken) throw new Error(`install token ${tag}`)
  return { tag, email, stackUser: j.user_id, session: j.access_token, user: t.user, team: ensured.body.value.personal_team as string, install: t.install, installToken, keyPair, canary }
}

type Row = { suite: string; name: string; pass: boolean; detail: string }
const rows: Array<Row> = []
const record = (suite: string, name: string, pass: boolean, detail = "") => { rows.push({ suite, name, pass, detail }); console.log(`${pass ? "PASS" : "FAIL"}  ${suite}: ${name}${detail ? ` -- ${detail}` : ""}`) }

const tenants: Array<Tenant> = []
try {
  const a = await makeTenant("a"); tenants.push(a)
  const b = await makeTenant("b"); tenants.push(b)
  console.log(`run ${run}: tenant A ${a.user} (team ${a.team}), tenant B ${b.user} (team ${b.team})`)

  // Tenant A's objects.
  const fixtures: Record<string, string> = { TeamId: a.team, UserId: a.user, InstallId: a.install }
  const learn = (r: Reply) => { if (ok(r)) for (const [k, v] of Object.entries(idsIn(r.body))) fixtures[k] ??= v }
  learn(await callOp(a.session, "group.create", { name: `${a.canary} group` }))
  const dm = await callOp(a.session, "dm.open", { peer: { email: `peer-${run}@example.test` } })
  learn(dm)
  const conv = dm.body?.value?.conversation?.id as string | undefined
  if (conv) { fixtures.ConversationId = conv; const k = crypto.randomUUID(); learn(await http("POST", "/v1/ops", a.session, { op: "message.send", params: { conversation: conv, client_msg_id: k, parts: [{ type: "text", text: `${a.canary} secret message` }] }, idempotency_key: k, origin: "cli" })) }
  learn(await callOp(a.session, "chief.create", {}))
  learn(await callOp(a.session, "feed.post", { type: "notice", kind: "notice", title: `${a.canary} feed` }))
  learn(await callOp(a.installToken, "host.enroll", { name: `${a.canary} host`, platform: "macos" }))
  record("fixtures", "tenant A owns a conversation, a group, a chief, a feed item and a host", ["ConversationId", "GroupId", "HostId"].every((k) => fixtures[k]), Object.keys(fixtures).join(","))

  const view = async () => {
    const out: Record<string, unknown> = {}
    for (const [op, p] of [["group.list", {}], ["inbox.list", { limit: 50 }], ["chief.list", {}], ["install.list", {}], ["feed.list", {}], ["team.hosts.list", {}], ["team.members.list", {}], ["team.directory", {}]] as const) out[op] = stable((await callRead(a.session, op, p)).body)
    if (fixtures.ConversationId) out.history = stable((await callRead(a.session, "conversation.history", { conversation: fixtures.ConversationId, limit: 50 })).body)
    return out
  }
  // A's own fan-out (the chief's conversation, the inbox rows) settles in the background; wait until two reads agree before the sweep.
  let before = await view()
  for (let i = 0; i < 10; i++) { await new Promise((r) => setTimeout(r, 1500)); const again = await view(); if (JSON.stringify(again) === JSON.stringify(before)) break; before = again }

  // 1. IDOR sweep.
  const leaks: Array<string> = []; const oracle: Array<string> = []; let reached = 0; let invalid = 0; let skipped = 0; let calls = 0
  for (const [name, def] of Object.entries(catalogOps)) {
    if (SKIP.test(name)) { skipped++; continue }
    const callers: Array<[string, string]> = []
    if (def.principals.includes("session")) callers.push(["session", b.session])
    if (def.principals.includes("install")) callers.push(["install", b.installToken])
    for (const [kind, token] of callers) {
      const sig = (r: Reply) => `${r.status} ${r.code ?? "ok"}`
      const own = ["install.sign_out", "install.register", "chief.create"].includes(name)
      const differs = (x: Reply, y: Reply) => !own && name !== "conversation.import" && (sig(x) !== sig(y) || (x.code === undefined && shape(x.raw) !== shape(y.raw)))
      let real = await call(def.class, token, name, sampleParams(name, fixtures)); calls++
      let control = await call(def.class, token, name, sampleParams(name, {})); calls++
      for (let retry = 0; retry < 2 && differs(real, control); retry++) { real = await call(def.class, token, name, sampleParams(name, fixtures)); control = await call(def.class, token, name, sampleParams(name, {})); calls += 2 }
      if (real.code === "validation.invalid") invalid++; else reached++
      if (real.raw.includes(a.canary) || real.raw.includes(a.email)) leaks.push(`${name} (${kind}): ${real.raw.slice(0, 160)}`)
      if (differs(real, control)) oracle.push(`${name} (${kind}): A-id ${sig(real)} | unknown ${sig(control)}`)
    }
  }
  console.log(`sweep: ${calls} calls, ${reached} reached authorization, ${invalid} stopped at validation, ${skipped} ops skipped (cost or side effect)`)
  record("idor", `no reply to B carries an A marker (${calls} calls)`, leaks.length === 0, leaks.slice(0, 5).join(" | "))
  record("idor", "A's ids answer exactly like unknown ids", oracle.length === 0, oracle.slice(0, 8).join(" | "))
  const after = await view()
  const changed = Object.keys(after).filter((k) => JSON.stringify(before[k]) !== JSON.stringify(after[k]))
  record("idor", "A's own view is unchanged after B's sweep", changed.length === 0, changed.map((k) => `${k}: ${JSON.stringify(before[k]).slice(0, 150)} => ${JSON.stringify(after[k]).slice(0, 150)}`).join(" | "))
  record("idor", "sweep reached authorization on most operations", reached / Math.max(1, reached + invalid) > 0.6, `${reached}/${reached + invalid}`)

  // 2. Forged and tampered tokens.
  const parts = a.session.split("."); const payload = JSON.parse(Buffer.from(parts[1]!, "base64url").toString())
  const tampered = `${parts[0]}.${Buffer.from(JSON.stringify({ ...payload, sub: b.stackUser })).toString("base64url")}.${parts[2]}`
  const noneToken = `${Buffer.from('{"alg":"none","typ":"JWT"}').toString("base64url")}.${Buffer.from(JSON.stringify({ sub: a.stackUser, aud: projectId })).toString("base64url")}.`
  const ip = a.installToken.split("."); const ipay = JSON.parse(Buffer.from(ip[1]!, "base64url").toString())
  const tamperedInstall = `${ip[0]}.${Buffer.from(JSON.stringify({ ...ipay, sub: b.user, team: b.team })).toString("base64url")}.${ip[2]}`
  for (const [name, token] of [["session token with sub edited to B", tampered], ["alg none", noneToken], ["install token with sub and team edited to B", tamperedInstall], ["random bearer", crypto.randomUUID()], ["no credential", undefined]] as const) {
    const r = await callRead(token, "install.list", {})
    record("tokens", `${name} -> 401`, r.status === 401, `status ${r.status}`)
  }
  const wrong = await http("POST", "/v1/auth/challenge", undefined, { user: b.user, install: a.install })
  record("tokens", "challenge for B's user on A's install is refused", wrong.status !== 200, `status ${wrong.status}`)
  const ch = await http("POST", "/v1/auth/challenge", undefined, { user: a.user, install: a.install })
  const forged = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, b.keyPair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const minted = await http("POST", "/v1/auth/token", undefined, { user: a.user, install: a.install, nonce: ch.body.nonce, signature: b64u(forged) })
  record("tokens", "A's install challenge signed with B's key mints nothing", minted.status !== 200 && !minted.raw.includes("access_token"), `status ${minted.status}`)
  const revokeByB = await callOp(b.session, "install.revoke", { install: a.install })
  record("tokens", "B cannot revoke A's install", !ok(revokeByB) && ok(await callRead(a.installToken, "install.list", {})), revokeByB.code ?? "")

  // 3. Wire sockets.
  const wireStatus = async (path: string, token: string, extra = "") => (await fetch(`${API}${path}`, { headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64"), "Sec-WebSocket-Protocol": `cmux.wire.v1${extra}`, authorization: `Bearer ${token}` } })).status
  if (conv) { const st = await wireStatus(`/v1/wire/conv/${conv}`, b.session); record("wire", "B cannot open A's conversation socket", [401, 403, 404].includes(st), `status ${st}`) }
  if (conv) { const st = await wireStatus(`/v1/wire/conv/${conv}`, a.session); record("wire", "control: A opens its own conversation socket", st === 101 || st === 200, `status ${st}`) }
  { const st = await wireStatus(`/v1/wire/team`, b.session, `, team.${a.team}`); record("wire", "B cannot select A's team on the team socket", [401, 403].includes(st), `status ${st}`) }

  // 4. Revocation is immediate.
  const gone = await makeTenant("c"); tenants.push(gone)
  record("tokens", "a fresh install token works before revoke", ok(await callRead(gone.installToken, "install.list", {})))
  await callOp(gone.session, "install.revoke", { install: gone.install })
  const post = await callRead(gone.installToken, "install.list", {})
  record("tokens", "the revoked install's token stops at once", post.status !== 200, `status ${post.status}`)
  record("tokens", "a revoked install mints no new token", (await mint(gone)) === undefined)
} finally {
  // Cleanup: revoke what we made, then delete the Stack users with the server key (never printed).
  const server = secrets.STACK_SECRET_SERVER_KEY
  for (const t of tenants) {
    await callOp(t.session, "install.revoke", { install: t.install }).catch(() => undefined)
    if (server) {
      const del = await fetch(`https://api.stack-auth.com/api/v1/users/${t.stackUser}`, { method: "DELETE", headers: { "x-stack-project-id": projectId, "x-stack-secret-server-key": server, "x-stack-access-type": "server" } })
      console.log(`cleanup: Stack user ${t.stackUser} (${t.email}) delete -> ${del.status}`)
    } else console.log(`cleanup: no server key; Stack user ${t.stackUser} (${t.email}) left`)
  }
}
const failed = rows.filter((r) => !r.pass)
console.log(`\n${rows.length - failed.length}/${rows.length} passed`)
if (reportPath) writeFileSync(reportPath, JSON.stringify({ run, api: API, at: new Date().toISOString(), rows }, null, 2))
process.exit(failed.length === 0 ? 0 : 1)
