import { env, exports } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import type { SubmitResult } from "../src/owner-do.ts"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { cloudTestUser } from "./setup/cloud-teams.ts"

/** Shared helpers for the bind, connect_info and link_token tests (state-placement.md 5.8). */

export type Frame = { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }
export interface BindBody {
  readonly team: string
  readonly machine: string
  readonly bind_token: string
  readonly wg_public_key: string
  readonly daemon: { readonly version: string; readonly capabilities: ReadonlyArray<string> }
  readonly install_public_jwk?: { readonly kty: string; readonly crv: string; readonly x: string; readonly y: string }
}
export interface CloudStub {
  submit(entity: string, principal: Principal, frame: Frame): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<any>
  bindMachine(entity: string, body: BindBody): Promise<{ ok: boolean; value?: any; code?: string; message?: string }>
  mintLinkToken(entity: string, principal: Principal, params: unknown): Promise<{ ok: boolean; value?: any; code?: string; message?: string }>
  fakeControl(cmd: { advance_ms?: number }): Promise<{ files: Array<{ name: string; path: string; content: string; mode: number }>; audit: Array<Record<string, unknown>>; now: number }>
}
const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
export const cloudStub = (team: string) => namespace.get(namespace.idFromName(team)) as unknown as CloudStub

// Users 50..99 of the allowlisted test users (other cloud test files use other ranges).
let seq = 50
export const person = (team?: string) => {
  const user = cloudTestUser(++seq)
  const t = team ?? personalTeamIdFor(user)
  const p: Principal = { identity: `user:${user}`, user, team: t, kind: "session" }
  return { team: t, user, p, stub: cloudStub(t) }
}
export const installOf = (p: Principal, classes: ReadonlyArray<string> = ["read", "mutate-own", "mutate-shared", "execute"], installKind = "cli"): Principal => {
  const install = `inst_${(p.user ?? "").slice(5, 9)}${"7".repeat(16)}`
  return { identity: `install:${install}`, user: p.user, team: p.team, kind: "install", install, grant_classes: [...classes], install_kind: installKind }
}
export const frame = (op: string, params: unknown, key: string = crypto.randomUUID()): Frame => ({ t: "op", op, params, idempotency_key: key, origin: "user" })
export const reply = (r: SubmitResult) => r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: any; code?: string; message?: string }
export const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
/** 32 bytes, standard base64: a WireGuard public key shape. */
export const WG_KEY = btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i + 1)))
export const DAEMON = { version: "0.41.0", capabilities: ["terminal", "files"] }

/** The bind file the create wrote into the fake VM. */
export const bindFile = async (stub: CloudStub, machine: string) => {
  const f = (await stub.fakeControl({})).files.find((x) => x.path === "/var/lib/cmux/bind.json" && JSON.parse(x.content).machine === machine)
  if (!f) throw new Error(`no bind file for ${machine}`)
  return { ...f, json: JSON.parse(f.content) as { team: string; machine: string; bind_token: string } }
}

/** The VM's install key pair (per clone): the bind request carries the public half (install_public_jwk). */
export const vmKey = async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const j = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  return { pair, jwk: { kty: "EC", crv: "P-256", x: j.x!, y: j.y! } }
}

/** The machine creator's UserDO must exist: bind registers the VM's install under the creator. */
export const ensureUser = async (x: { user: string; team: string }) => {
  const ns = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
  const stub = ns.get(ns.idFromName(x.user)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<SubmitResult> }
  await stub.submit(x.user, { identity: `user:${x.user}`, user: x.user, team: x.team, kind: "session", stack_user_id: `stack_${x.user}`, email: `${x.user}@example.com` }, { t: "op", op: "user.ensure", params: {}, idempotency_key: `ensure-${x.user}`, origin: "user" })
}

/** A bind body for `machine` with a fresh VM install key (and the creator's UserDO ensured). */
export const bindBody = async (x: { user: string; team: string }, machine: string, bindToken: string) => {
  await ensureUser(x)
  const key = await vmKey()
  return { body: { team: x.team, machine, bind_token: bindToken, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk }, key }
}

/** Create a machine and bind it with the token from its bind file. */
export const createdAndBound = async (x: ReturnType<typeof person>) => {
  const created = reply(await x.stub.submit(x.team, x.p, frame("cloud.machine.create", { size: SIZE })))
  if (created.t !== "result") throw new Error(JSON.stringify(created))
  const machine = created.value.machine.id as string
  const file = await bindFile(x.stub, machine)
  const { body, key } = await bindBody(x, machine, file.json.bind_token)
  const bound = await x.stub.bindMachine(x.team, body)
  if (!bound.ok) throw new Error(JSON.stringify(bound))
  return { machine, host: bound.value.host as string, keyset: bound.value.keyset as { version: string; keys: Record<string, JWK> }, install: bound.value.install as { id: string; user: string; grant: string }, key }
}

// ---- Worker-level helpers
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
export const worker = (exports as unknown as { default: Fetcher }).default
export const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
export const post = async (path: string, token: string | undefined, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return { status: res.status, body: (await res.json()) as any }
}
const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/** A signed-in person with a registered mac install and an install token for it. */
export const signedInWithInstall = async (sub: string, kind = "mac") => {
  const session = await sessionToken(sub)
  const ensured = (await post("/v1/ops", session, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const reg = await post("/v1/ops", session, {
    op: "install.register",
    params: { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind, name: kind, device_name: kind, platform: "macos" },
    idempotency_key: crypto.randomUUID(),
    origin: "user"
  })
  const install = reg.body.value.id as string
  const ch = await post("/v1/auth/challenge", undefined, { user: ensured.id, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.body.message_prefix}${ch.body.nonce}`))
  const tok = await post("/v1/auth/token", undefined, { user: ensured.id, install, nonce: ch.body.nonce, signature: b64u(sig) })
  return { session, installToken: tok.body.access_token as string, user: ensured.id as string, team: ensured.personal_team as string, install }
}
