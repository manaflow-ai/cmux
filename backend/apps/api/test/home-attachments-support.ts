import { env, exports } from "cloudflare:workers"
import { runInDurableObject as runInDO } from "cloudflare:test"
import { createHash } from "node:crypto"
import { invites } from "@cmux/home-core"
import type { Principal } from "@cmux/ownership"
import { importJWK, SignJWT, type JWK } from "jose"
import { expect } from "vitest"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"

/** Shared helpers of the Home attachment tests (home-attachments.test.ts, home-attachments-review.test.ts). */
export const testEnv = env as unknown as Env & { STACK_TEST_PRIVATE_JWK: string; HOME_ATTACHMENTS: R2Bucket }
export const worker = (exports as unknown as { default: Fetcher }).default
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const runInDurableObject = runInDO as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
export type Stub = { submit(e: string, p: Principal, f: unknown): Promise<{ frames: Array<{ t: string; code?: string }> }> }
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const stub = (ns: any, name: string): Stub => ns.get(ns.idFromName(name))

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
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body)
  })
  return { status: res.status, json: (await res.json().catch(() => null)) as any }
}
export const op = (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => post("/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })

export interface Who {
  token: string
  user: string
  principal: Principal
}
export const signIn = async (sub: string): Promise<Who> => {
  const token = await sessionToken(sub)
  expect((await op(token, "user.ensure", {})).json.ok).toBe(true)
  const user = userIdFor(testEnv.STACK_PROJECT_ID, sub)
  return { token, user, principal: { kind: "session", identity: `session:${user}`, user, team: personalTeamIdFor(user), display_name: sub, email: `${sub}@example.com`, email_verified: true } }
}

/** Valid Crockford ids (the Worker's conversation id rule). */
export const convId = () => `conv_01J${Array.from(crypto.getRandomValues(new Uint8Array(23)), (b) => "0123456789ABCDEFGHJKMNPQRSTVWXYZ"[b % 32]).join("")}`
export const result = (r: { frames: Array<{ t: string; code?: string }> }) => r.frames.find((f) => f.t === "result" || f.t === "reject")

/** A group of `owner` (+ `members`, joined through an approved invite) with the given history setting. */
export const group = async (owner: Who, members: Array<Who> = [], historyVisible: "all" | "since_join" = "all") => {
  const id = convId()
  const conv = stub(testEnv.CONVERSATION_DO, id)
  const ok = async (who: Principal, o: string, params: unknown, key: string) => expect(result(await conv.submit(id, who, { t: "op", op: o, params, idempotency_key: key }))).toMatchObject({ t: "result" })
  await ok(owner.principal, "conversation.create", { id, kind: "group", title: "Files", participants: [{ id: owner.user, kind: "human", display_name: "Owner" }] }, "c")
  if (historyVisible === "since_join") await ok(owner.principal, "conversation.settings.set", { history_visible: "since_join" }, "s")
  const g = { id, conv, ok, join: (m: Who, i: number) => join(id, ok, owner, m, i) }
  for (const [i, m] of members.entries()) await g.join(m, i)
  return g
}
export const join = async (id: string, ok: (w: Principal, o: string, p: unknown, k: string) => Promise<void>, owner: Who, m: Who, i: number) => {
  const proof = invites.hashInviteSecret(`secret-${id}-${i}`)
  const invite = `inv_${String(i).padStart(26, "0")}`
  await ok(owner.principal, "invite.create", { invite_id: invite, address: `addr_${String(i).padStart(26, "0")}`, channel: "sms", display_name: "M", token_hash: invites.hashInviteSecret(proof), locale: "en", copy_variant: "A" }, `i${i}`)
  await ok(m.principal, "invite.accept", { proof }, `a${i}`)
  await ok(owner.principal, "invite.approve_join", { invite_id: invite }, `ap${i}`)
}

export const text = (t: string) => ({ type: "text", text: t })
export const bytesOf = (s: string) => new TextEncoder().encode(s)
export const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex")
export const intent = (who: Who, conversation: string, body: Uint8Array, over: Record<string, unknown> = {}) =>
  post("/v1/home/attachments/intent", who.token, { conversation, sha256: sha(body), byte_count: body.byteLength, mime_type: "image/png", name: "pic.png", width: 2, height: 2, ...over })
export const put = (url: string, body: Uint8Array) => worker.fetch(url, { method: "PUT", body, headers: { "content-length": String(body.byteLength) } })
/** Intent + upload; returns the hash. */
export const upload = async (who: Who, conversation: string, body: Uint8Array, over: Record<string, unknown> = {}) => {
  const r = await intent(who, conversation, body, over)
  expect(r.json.ok).toBe(true)
  if (r.json.value.state === "upload") expect((await put(r.json.value.upload_url, body)).status).toBe(200)
  return sha(body)
}
export const urlFor = (who: Who, conversation: string, hash: string, at?: { message_id: string; part_index: number }) => post("/v1/home/attachments/url", who.token, { conversation, hash, ...at })
/** The opaque object id in a minted download URL. */
export const objectIdOf = (url: string) => new URL(url).pathname.split("/").pop()!
export const attachmentPart = (hash: string, body: Uint8Array, over: Record<string, unknown> = {}) => ({ type: "attachment", hash, name: "pic.png", mime_type: "image/png", byte_count: body.byteLength, width: 2, height: 2, ...over })
