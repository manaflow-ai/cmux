import type { OwnerFrame, Principal } from "@cmux/ownership"
import { PairingInfo, PublicJwk, WgPublicKey } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { verifyInstallSignature } from "./auth.ts"
import type { Env } from "./env.ts"
import { BEGIN_SKEW_MS, beginProofMessage, codeFromRandom, displayCode, normalizeCode, sha256Hex } from "./domains/pairing.ts"
import { jwkThumbprint } from "./domains/user.ts"
import type { PairingRecord, PairingResult } from "./pairing-do.ts"

/**
 * cmux server pairing routes (plans/cmux-next/server.md 6.2).
 *
 * - `POST /v1/pair/begin` (no account): a server proves it holds its install key
 *   and gets a code plus a collect secret. Rate-limited per client IP.
 * - `GET /v1/pair/wait` (WebSocket, subprotocols `cmux.pair.v1, collect.<secret>`):
 *   the server waits for approval; the result is pushed, never polled.
 * - `server.pair.preview` / `server.pair.approve` run through `/v1/ops` with a
 *   signed-in session (see http.ts), never an install token or an agent.
 */

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

const BeginBody = Schema.Struct({
  public_jwk: PublicJwk,
  wg_public_key: WgPublicKey,
  info: PairingInfo,
  issued_at: Schema.Int,
  signature: Schema.String.check(Schema.isMaxLength(200))
})

const pairingStub = (env: Env, code: string) => env.PAIRING_DO.get(env.PAIRING_DO.idFromName(code))

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

export const handlePairBegin = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  // Per client IP, before any PairingDO wakes.
  if (env.PAIR_BEGIN_LIMIT) {
    const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" })
    if (!success) return json({ error: "rate limited" }, 429)
  }
  let raw: unknown
  try {
    raw = await request.json()
  } catch {
    return json({ error: "invalid json" }, 400)
  }
  const exit = Schema.decodeUnknownExit(BeginBody)(raw)
  if (!Exit.isSuccess(exit)) return json({ error: "invalid pairing request" }, 400)
  const body = exit.value
  const now = Date.now()
  if (Math.abs(now - body.issued_at) > BEGIN_SKEW_MS) return json({ error: "clock skew too large" }, 400)
  const thumbprint = jwkThumbprint(body.public_jwk)
  const proof = beginProofMessage(env.ENVIRONMENT, thumbprint, body.wg_public_key, body.issued_at)
  if (!(await verifyInstallSignature(body.public_jwk, proof, body.signature))) return json({ error: "proof of possession failed" }, 403)
  const collect = b64u(crypto.getRandomValues(new Uint8Array(32)))
  const collectHash = await sha256Hex(collect)
  const country = ((request as unknown as { cf?: { country?: string } }).cf?.country ?? null) || null
  // 40-bit codes: a collision with a live code is rare; try a few fresh codes.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = codeFromRandom(crypto.getRandomValues(new Uint8Array(5)))
    const r = await pairingStub(env, code).begin({ code, public_jwk: body.public_jwk, thumbprint, wg_public_key: body.wg_public_key, info: body.info, country, collect_hash: collectHash, now })
    if (r.ok) {
      const origin = (env.DASHBOARD_ORIGIN ?? "").replace(/\/$/, "")
      return json({ code, display: displayCode(code), expires_at: r.expires_at, collect_secret: collect, thumbprint, verification_uri: `${origin}/pair?c=${code}` })
    }
  }
  return json({ error: "no free pairing code, try again" }, 503)
}

export const handlePairWait = async (request: Request, env: Env): Promise<Response> => {
  if (request.headers.get("Upgrade") !== "websocket") return json({ error: "websocket required" }, 426)
  const code = normalizeCode(new URL(request.url).searchParams.get("code") ?? "")
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim())
  const secret = protocols.find((p) => p.startsWith("collect."))?.slice("collect.".length)
  if (!code || !secret) return json({ error: "code and collect secret required" }, 400)
  const headers = new Headers(request.headers)
  headers.set("x-cmux-collect-hash", await sha256Hex(secret))
  return pairingStub(env, code).fetch(new Request(request.url, { headers, method: "GET" }))
}

type OpReply = {
  ok: boolean
  op: string
  value?: unknown
  error?: { code: string; message: string; retryable: boolean }
  transaction: string
  idempotency_key: string
  replayed: boolean
  stream: string
  sequence: number
}

const fail = (op: string, key: string, code: string, message: string, retryable = false): OpReply => ({
  ok: false,
  op,
  error: { code, message, retryable },
  transaction: "",
  idempotency_key: key,
  replayed: false,
  stream: "",
  sequence: 0
})

/** A user-origin session only: never an install token, never an agent acting through one. */
const isHumanSession = (p: Principal) => p.kind === "session" && !p.agent && Boolean(p.user)

/** Per-user limit on preview and approve (code guessing), on the pairing namespace with user keys. */
const pairLimited = async (env: Env, principal: Principal): Promise<boolean> => {
  if (!env.PAIR_BEGIN_LIMIT) return true
  const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: `user:${principal.user}` })
  return success
}

export const pairPreview = async (env: Env, principal: Principal, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }> => {
  if (!isHumanSession(principal)) return { ok: false, code: "auth.forbidden", message: "pairing needs a signed-in user" }
  if (!(await pairLimited(env, principal))) return { ok: false, code: "auth.forbidden", message: "too many pairing requests" }
  const code = normalizeCode(String((params as { code?: unknown } | null)?.code ?? ""))
  if (!code) return { ok: false, code: "validation.invalid", message: "invalid pairing code" }
  const r: PairingRecord | null = await pairingStub(env, code).preview(code, Date.now())
  if (!r) return { ok: false, code: "selector.not_found", message: "pairing code expired or unknown" }
  return { ok: true, value: { code: r.code, info: r.info, public_jwk: r.public_jwk, thumbprint: r.thumbprint, country: r.country, expires_at: r.expires_at } }
}

/**
 * server.pair.approve: register the server's install key under the approver
 * (narrow grant), add the host to the team, then push the result to the
 * waiting server. Each step is keyed by the code, so a retry finishes a
 * partial approval and never makes a second install or host.
 */
export const pairApprove = async (
  env: Env,
  principal: Principal,
  frame: { op: string; params: unknown; idempotency_key: string },
  submit: (owner: "cloud:UserDO", p: Principal, f: { op: string; params: unknown; idempotency_key: string; origin: string }) => Promise<{ frames: ReadonlyArray<OwnerFrame> }>
): Promise<OpReply> => {
  const op = frame.op
  if (!isHumanSession(principal)) return fail(op, frame.idempotency_key, "auth.forbidden", "pairing needs a signed-in user")
  const params = (frame.params ?? {}) as { code?: unknown; team?: unknown; name?: unknown }
  const code = normalizeCode(String(params.code ?? ""))
  if (!code) return fail(op, frame.idempotency_key, "validation.invalid", "invalid pairing code")
  // Phase 1 routes TeamDO by the token's team only (http.ts ownerRoute); another team is refused, not guessed.
  if (params.team !== principal.team) return fail(op, frame.idempotency_key, "auth.forbidden", "pairing into another team is not supported yet")
  const name = typeof params.name === "string" && params.name.length >= 1 && params.name.length <= 80 ? params.name : null
  if (!name) return fail(op, frame.idempotency_key, "validation.invalid", "name must be 1 to 80 characters")
  if (!(await pairLimited(env, principal))) return fail(op, frame.idempotency_key, "auth.forbidden", "too many pairing requests, try again in a minute", true)
  const team = principal.team!
  // Role first: an approver who may not add servers writes nothing anywhere.
  if (!(await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).canEnrollServer(team, principal))) {
    return fail(op, frame.idempotency_key, "auth.forbidden", "only team owners and admins may add a server")
  }
  const stub = pairingStub(env, code)
  // Claim before any write: concurrent approvals by different users cannot both register an install and a host.
  const claimed = await stub.claim(code, principal.user!, Date.now())
  if (!claimed.ok) {
    return claimed.reason === "unknown" ? fail(op, frame.idempotency_key, "selector.not_found", "pairing code expired or unknown") : fail(op, frame.idempotency_key, "auth.forbidden", "pairing code already used")
  }
  const done = (result: PairingResult): OpReply => ({ ok: true, op, value: result, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `team:${result.team}`, sequence: 0 })
  if (claimed.result) return done(claimed.result)
  const rec = claimed.record
  const reg = await submit("cloud:UserDO", principal, {
    op: "install.register",
    params: { public_jwk: rec.public_jwk, kind: "daemon", name, device_name: rec.info.name, platform: rec.info.platform, op_classes: ["read", "mutate-own"], bound_team: principal.team },
    idempotency_key: `pair:${code}:${rec.thumbprint}:install`,
    origin: "user"
  })
  const regReply = reg.frames.find((f) => f.t === "result" || f.t === "reject")
  if (!regReply || regReply.t !== "result") return fail(op, frame.idempotency_key, regReply && regReply.t === "reject" ? regReply.code : "owner.unreachable", regReply && regReply.t === "reject" ? regReply.message : "install registration failed", true)
  const install = (regReply.value as { id: string }).id
  const enrolled = await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).enrollServer(
    team,
    principal,
    { install, name, platform: rec.info.platform, wg_public_key: rec.wg_public_key },
    `pair:${code}:${rec.thumbprint}:host`
  )
  if (!enrolled.ok) return fail(op, frame.idempotency_key, enrolled.code, enrolled.message)
  const result: PairingResult = { host: enrolled.host, team, user: principal.user!, install }
  const c = await stub.complete(code, rec.thumbprint, result, Date.now())
  if (!c.ok) return fail(op, frame.idempotency_key, "validation.invalid", c.message)
  return done(result)
}
