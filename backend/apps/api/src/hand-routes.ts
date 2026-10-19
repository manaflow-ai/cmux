import { stackServer } from "./stack-server.ts"
import { authenticate } from "./auth.ts"
import type { Env } from "./env.ts"
import { apiOrigin, handStub, indexStub, listHands, mintPairCode } from "./hand-api.ts"
import { handInstallScript } from "./hand-install.ts"
import { createSandbox } from "./hand-sandbox.ts"
import { proofOf } from "./hand-levels.ts"
import { HAND_ID, PAIR_CODE, sha256Hex, type HandCaller, type HandReply } from "./hand-wire.ts"
import { callerOf } from "./home-attachments.ts"
import { chiefOwnedBy } from "./chief-brain/brain-io.ts"

/**
 * Hand routes (outside the op catalog, like the keyed acpmux start):
 *
 *   GET    /hand/install.sh                          the installer (no auth; it verifies what it downloads)
 *   POST   /v1/hands/pair                            the hand: {code, key_sha256, name, profile, ...}; the code is the credential
 *   GET    /v1/hands/<hand>/socket                   the hand's socket; Authorization: Bearer <hand key>
 *   POST   /v1/hands/pair-codes                      the person: {name?, profile?} -> {hand, code, expires_at, install}
 *   GET    /v1/hands                                 the person: their hands
 *   POST   /v1/hands/sandboxes                       the person: {name, provider?} -> a new sandbox with its hand (hand-providers.ts)
 *   PUT    /v1/hands/grants/<agent>                  the person: {on: boolean} a Chief's hands grant
 *   GET    /v1/hands/<hand>                          the person: one hand and its hello
 *   DELETE /v1/hands/<hand>                          the person: remove (the key stops working at once)
 *   POST   /v1/hands/<hand>/call                     the person: {action, params, timeout_ms?}
 *   GET    /v1/hands/<hand>/audit                    the person: newest audit rows
 *   GET    /v1/hands/<hand>/events?session=&after_seq=&wait_ms=   the person: agent events (waits up to 30 s for the next)
 *   POST   /v1/hands/<hand>/level-challenge          the person: a single-use nonce for raising the level
 *   PUT    /v1/hands/<hand>/level                    the person: {level, install?, nonce?, signature?}; raising needs the app proof
 *   GET    /v1/hands/presence-key?install=I          the person: {gen, thumbprint} that a replacement's current-key signature covers
 *   PUT    /v1/hands/presence-key                    the person: {install, public_jwk, signature, current_signature?, attestation?, key_id?}: a Touch ID / Face ID key for raises
 *   POST   /v1/hands/defaults/<profile>/challenge    the person: a nonce for raising the default level of new hands
 *   PUT    /v1/hands/defaults/<profile>              the person: {level, ...proof} the default level of new hands
 *   GET    /v1/hands/<hand>/verdicts                 the person: the classifier's verdicts (mac hands), newest first
 *   GET    /v1/hands/<hand>/approvals                the person: requests waiting for them (mac hands)
 *   POST   /v1/hands/<hand>/approvals/<id>           the person: {allow, install?, signature?}; an allow needs the app proof over `sign`
 *
 * "The person" is a Stack session (no install or Chief token): a Chief reaches hands only through
 * its brain's tools (chief-brain/brain-hands.ts), which build the caller in server code.
 */
export const HAND_PATH = /^\/(?:hand\/install\.sh|v1\/hands(?:\/.*)?)$/

const NO_STORE = { "cache-control": "no-store" }
const fail = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message } }, { status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const STATUS: Readonly<Record<string, number>> = { "hand.level_refused": 403, "hand.presence_refused": 403, "hand.approval_proof": 403, "hand.read_only": 403, "hand.not_found": 404, "hand.no_grant": 403, "hand.revoked": 410, "hand.mac_disabled": 403, "hand.offline": 409, "hand.timeout": 504, "hand.pair_invalid": 400, "auth.forbidden": 403 }
const reply = (r: HandReply) => (r.ok ? ok(r.value) : Response.json({ ok: false, error: r.error }, { status: STATUS[r.error.code] ?? 400, headers: NO_STORE }))

const person = async (request: Request, env: Env): Promise<{ caller: HandCaller; principal: Parameters<typeof chiefOwnedBy>[2] } | Response> => {
  const c = await callerOf(request, env, "read")
  if ("status" in c) return fail(c.status, c.code, c.message)
  if (c.principal.kind !== "session" || c.principal.agent !== undefined) return fail(403, "auth.forbidden", "hands are managed with a person's session")
  return { caller: { kind: "owner", user: c.user }, principal: c.principal }
}

/**
 * When the caller's Stack session was signed in (its refresh_token_id's created_at), or null when
 * not known. The bearer token is read again here: the request principal (callerOf) drops the
 * Stack session id.
 */
const sessionSignedInAt = async (env: Env, request: Request): Promise<number | null> => {
  const auth = request.headers.get("authorization") ?? ""
  const p = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined).catch(() => undefined)
  if (p?.kind !== "session" || !p.stack_user_id || !p.stack_session) return null
  return (await stackServer(env)?.sessionCreatedAt(p.stack_user_id, p.stack_session).catch(() => null)) ?? null
}

const body = async (request: Request): Promise<Record<string, unknown> | null> => {
  const b = (await request.json().catch(() => null)) as unknown
  return b && typeof b === "object" && !Array.isArray(b) ? (b as Record<string, unknown>) : null
}

const pair = async (request: Request, env: Env): Promise<Response> => {
  if (env.PAIR_BEGIN_LIMIT) {
    const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: `hand-pair:${request.headers.get("cf-connecting-ip") ?? "local"}` })
    if (!success) return fail(429, "rate_limited", "too many pairing attempts")
  }
  const b = await body(request)
  const m = typeof b?.code === "string" ? PAIR_CODE.exec(b.code) : null
  const keySha = typeof b?.key_sha256 === "string" && /^[0-9a-f]{64}$/.test(b.key_sha256) ? b.key_sha256 : null
  if (!b || !m || !keySha) return fail(400, "validation.invalid", "body is {code, key_sha256 (64 hex), name, profile}")
  const profile = b.profile === "mac" ? "mac" : "sandbox"
  const name = typeof b.name === "string" ? b.name.slice(0, 80) : ""
  return reply(await handStub(env, m[1]!).redeem(await sha256Hex(m[2]!), keySha, { name, profile, os: typeof b.os === "string" ? b.os : undefined }))
}

const socket = async (request: Request, env: Env, hand: string): Promise<Response> => {
  if (request.headers.get("Upgrade") !== "websocket") return fail(426, "upgrade_required", "expected a WebSocket upgrade")
  const auth = request.headers.get("authorization") ?? ""
  const key = auth.startsWith("Bearer ") ? auth.slice(7).trim() : ""
  if (!/^[A-Za-z0-9_-]{43}$/.test(key)) return fail(401, "auth.unauthenticated", "the hand key is required")
  // Only the hash reaches the object; the key itself never leaves this request.
  const headers = new Headers({ Upgrade: "websocket", "x-cmux-hand-key-sha256": await sha256Hex(key) })
  return handStub(env, hand).fetch(new Request("https://hand.internal/socket", { headers, method: "GET" }))
}

export const handleHands = async (request: Request, env: Env, path: string): Promise<Response> => {
  // Hands serve the Cloud Chief brain: off wherever the brain is off, and wherever HANDS_ENABLED is not "1" (production today).
  if (env.CHIEF_BRAIN_ENABLED !== "1" || env.HANDS_ENABLED !== "1") return fail(404, "not_found", "hands are off on this deployment")
  if (path === "/hand/install.sh") {
    if (request.method !== "GET") return fail(405, "method_not_allowed", "GET")
    return handInstallScript(env, apiOrigin(env, request))
  }
  if (path === "/v1/hands/pair") return request.method === "POST" ? pair(request, env) : fail(405, "method_not_allowed", "POST")
  const sock = path.match(/^\/v1\/hands\/(hand_[a-z2-7]{20})\/socket$/)
  if (sock) return socket(request, env, sock[1]!)

  const who = await person(request, env)
  if (who instanceof Response) return who
  const { caller, principal } = who
  if (path === "/v1/hands/pair-codes") {
    if (request.method !== "POST") return fail(405, "method_not_allowed", "POST")
    const b = (await body(request)) ?? {}
    const profile = b.profile === "mac" ? "mac" : "sandbox"
    return reply(await mintPairCode(env, caller, typeof b.name === "string" ? b.name : "", apiOrigin(env, request), profile))
  }
  if (path === "/v1/hands/sandboxes") {
    if (request.method !== "POST") return fail(405, "method_not_allowed", "POST")
    const b = (await body(request)) ?? {}
    return reply(await createSandbox(env, caller, typeof b.name === "string" ? b.name : "", typeof b.provider === "string" ? b.provider : undefined))
  }
  if (path === "/v1/hands") return request.method === "GET" ? reply(await listHands(env, caller)) : fail(405, "method_not_allowed", "GET")
  // The presence key (Touch ID / Face ID) of one of the owner's app installs, signed by its install key (hand-levels.ts).
  if (path === "/v1/hands/presence-key") {
    if (request.method === "GET") {
      const install = new URL(request.url).searchParams.get("install") ?? ""
      if (!/^inst_[A-Za-z0-9_-]{1,80}$/.test(install)) return fail(400, "validation.invalid", "?install=<install id>")
      return reply(await indexStub(env, caller.user).presenceOf(caller, caller.user, install))
    }
    if (request.method !== "PUT") return fail(405, "method_not_allowed", "GET or PUT")
    const b = await body(request)
    if (typeof b?.install !== "string" || typeof b.signature !== "string") return fail(400, "validation.invalid", "body is {install, public_jwk, signature, current_signature?, attestation?, key_id?}")
    // A replacement may pass on a fresh sign-in (also when a current-key signature is sent and fails): when this session was signed in.
    const signedInAt = await sessionSignedInAt(env, request)
    return reply(await indexStub(env, caller.user).registerPresence(caller, caller.user, {
      install: b.install,
      jwk: b.public_jwk,
      signature: b.signature,
      ...(typeof b.current_signature === "string" ? { current_signature: b.current_signature } : {}),
      ...(typeof b.attestation === "string" ? { attestation: b.attestation, ...(typeof b.key_id === "string" ? { key_id: b.key_id } : {}) } : {}),
      signed_in_at: signedInAt
    }))
  }
  // The owner's default level for new hands of a profile (hand-levels.ts).
  const defaults = path.match(/^\/v1\/hands\/defaults\/(sandbox|mac)(\/challenge)?$/)
  if (defaults) {
    const index = indexStub(env, caller.user)
    const profile = defaults[1] as "sandbox" | "mac"
    if (defaults[2]) return request.method === "POST" ? ok(await index.defaultChallenge(profile)) : fail(405, "method_not_allowed", "POST")
    if (request.method !== "PUT") return fail(405, "method_not_allowed", "PUT")
    const b = await body(request)
    return reply(await index.setOwnerDefault(caller, caller.user, profile, typeof b?.level === "string" ? b.level : "", proofOf(b)))
  }
  const grant = path.match(/^\/v1\/hands\/grants\/(agent_[0-9A-HJKMNP-TV-Z]{26})$/)
  if (grant) {
    if (request.method !== "PUT") return fail(405, "method_not_allowed", "PUT")
    const b = await body(request)
    if (typeof b?.on !== "boolean") return fail(400, "validation.invalid", "body is {on: boolean}")
    if (!(await chiefOwnedBy(env, grant[1]!, principal))) return fail(403, "auth.forbidden", "only the Chief's owner grants it hands")
    return ok({ grants: await indexStub(env, caller.user).setGrant(grant[1]!, b.on) })
  }
  const m = path.match(/^\/v1\/hands\/(hand_[a-z2-7]{20})(?:\/(call|audit|events|verdicts|level|level-challenge|approvals)(?:\/([0-9a-f-]{36}))?)?$/)
  if (!m || !HAND_ID.test(m[1]!)) return fail(404, "not_found", "not found")
  const stub = handStub(env, m[1]!)
  const [, , sub, approval] = m
  if (!sub) {
    if (request.method === "GET") return reply(await stub.info(caller))
    if (request.method === "DELETE") return reply(await stub.revoke(caller))
    return fail(405, "method_not_allowed", "GET or DELETE")
  }
  if (sub === "call") {
    if (request.method !== "POST") return fail(405, "method_not_allowed", "POST")
    const b = await body(request)
    if (!b || typeof b.action !== "string") return fail(400, "validation.invalid", "body is {action, params, timeout_ms?}")
    return reply(await stub.call(caller, b.action, b.params ?? {}, typeof b.timeout_ms === "number" ? b.timeout_ms : undefined))
  }
  if (sub === "events") {
    const q = new URL(request.url).searchParams
    return request.method === "GET" ? reply(await stub.events(caller, q.get("session") ?? "", Number(q.get("after_seq")) || 0, Number(q.get("wait_ms")) || 0)) : fail(405, "method_not_allowed", "GET")
  }
  if (sub === "level-challenge") return request.method === "POST" ? reply(await stub.levelChallenge(caller)) : fail(405, "method_not_allowed", "POST")
  if (sub === "level") {
    if (request.method !== "PUT") return fail(405, "method_not_allowed", "PUT")
    const b = await body(request)
    return reply(await stub.setLevel(caller, typeof b?.level === "string" ? b.level : "", proofOf(b)))
  }
  if (sub === "verdicts") return request.method === "GET" ? reply(await stub.verdicts(caller, Number(new URL(request.url).searchParams.get("limit")) || 100)) : fail(405, "method_not_allowed", "GET")
  if (sub === "audit") return request.method === "GET" ? reply(await stub.auditLog(caller, Number(new URL(request.url).searchParams.get("limit")) || 100)) : fail(405, "method_not_allowed", "GET")
  if (!approval) return request.method === "GET" ? reply(await stub.approvals(caller)) : fail(405, "method_not_allowed", "GET")
  if (request.method !== "POST") return fail(405, "method_not_allowed", "POST")
  const b = await body(request)
  if (typeof b?.allow !== "boolean") return fail(400, "validation.invalid", "body is {allow: boolean}")
  return reply(await stub.answer(caller, approval, b.allow, { install: typeof b.install === "string" ? b.install : undefined, signature: typeof b.signature === "string" ? b.signature : undefined }))
}
