import type { OwnerFrame, Principal } from "@cmux/ownership"
import { PairingInfo, PublicJwk, WgPublicKey } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { verifyInstallSignature } from "./auth.ts"
import type { Env } from "./env.ts"
import { BEGIN_SKEW_MS, beginProofMessage, codeFromRandom, displayCode, normalizeCode, sha256Hex } from "./domains/pairing.ts"
import { jwkThumbprint } from "./domains/user.ts"
import { collectSecret, collectSecretValid } from "./pair-collect.ts"
import type { PairingRecord, PairingResult } from "./pairing-do.ts"

/**
 * cmux server pairing routes (plans/cmux-next/server.md 6.2).
 *
 * - `POST /v1/pair/begin` (no account): a server proves it holds its install key
 *   and gets a code plus a collect secret. Rate-limited per client IP.
 * - `GET /v1/pair/wait` (WebSocket, subprotocols `cmux.pair.v1, collect.<secret>`):
 *   the server waits for approval; the result is pushed, never polled. The
 *   Worker checks the secret (an HMAC over the code, pair-collect.ts) before
 *   any PairingDO wakes.
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
  const country = ((request as unknown as { cf?: { country?: string } }).cf?.country ?? null) || null
  // 40-bit codes: a collision with a live code is rare; try a few fresh codes.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = codeFromRandom(crypto.getRandomValues(new Uint8Array(5)))
    const collect = await collectSecret(env, code)
    const collectHash = await sha256Hex(collect)
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
  // Stateless check before any PairingDO wakes: a forged code or secret creates no object.
  if (!(await collectSecretValid(env, code, secret))) return json({ error: "not found" }, 404)
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

/**
 * Per-user limits on the pairing namespace (user keys). `user` bounds preview
 * and approve (code guessing); `user-retry` is spent only after `user` refused,
 * by an approve that may be a retry of the caller's own claim, so a retry is
 * never blocked by the guessing budget and PairingDO wakes stay bounded.
 */
const pairLimited = async (env: Env, principal: Principal, bucket: "user" | "user-retry" = "user"): Promise<boolean> => {
  if (!env.PAIR_BEGIN_LIMIT) return true
  const { success } = await env.PAIR_BEGIN_LIMIT.limit({ key: `${bucket}:${principal.user}` })
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
 * The principal pairing registers the daemon install with (a server kind: never declared by a client).
 * Built by the Worker for the approving user; it keeps the approver's SSO team (resolved in http.ts),
 * so the daemon in an SSO-required team is bound like a session-registered install.
 */
export const pairingServerPrincipal = (approver: Principal, team: string): Principal => ({
  identity: `system:pairing:${team}`,
  kind: "system",
  user: approver.user,
  team,
  ...(approver.sso_team ? { sso_team: approver.sso_team } : {})
})

/**
 * server.pair.approve: register the server's install key under the approver
 * (narrow grant), add the host to the team, then push the result to the
 * waiting server. Each step is keyed by the code, so a retry finishes a
 * partial approval and never makes a second install or host. When the
 * approver loses the role after the install is registered, TeamDO refuses the
 * host and revokes that install in one commit, and the code is spent.
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
  const team = principal.team!
  const stub = pairingStub(env, code)
  const now = Date.now()
  // Limit before any PairingDO wakes. When the guessing budget is spent, a retry of the caller's own
  // claim may still pass on the retry budget; only then is PairingDO asked (read only).
  let mine: boolean | undefined
  if (!(await pairLimited(env, principal))) {
    mine = (await pairLimited(env, principal, "user-retry")) && (await stub.claimedBy(code, principal.user!, now))
    if (!mine) return fail(op, frame.idempotency_key, "auth.forbidden", "too many pairing requests, try again in a minute", true)
  }
  // Role first: an approver who may not add servers writes nothing anywhere. One exception: the
  // approver already claimed this code (an earlier attempt may have registered the install), so the
  // retry goes on and TeamDO refuses in one commit with the install's revocation, then the code is spent.
  if (!(await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).canEnrollServer(team, principal))) {
    if (!(mine ?? (await stub.claimedBy(code, principal.user!, now)))) return fail(op, frame.idempotency_key, "auth.forbidden", "only team owners and admins may add a server")
  }
  // Claim before any write: concurrent approvals by different users cannot both register an install and a host.
  const claimed = await stub.claim(code, principal.user!, now)
  if (!claimed.ok) {
    return claimed.reason === "unknown" ? fail(op, frame.idempotency_key, "selector.not_found", "pairing code expired or unknown") : fail(op, frame.idempotency_key, "auth.forbidden", "pairing code already used")
  }
  const done = (result: PairingResult): OpReply => ({ ok: true, op, value: result, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `team:${result.team}`, sequence: 0 })
  if (claimed.result) return done(claimed.result)
  const rec = claimed.record
  const reg = await submit("cloud:UserDO", pairingServerPrincipal(principal, team), {
    op: "install.register_server",
    params: { public_jwk: rec.public_jwk, kind: "daemon", name, device_name: rec.info.name, platform: rec.info.platform, op_classes: ["read", "mutate-own"], bound_team: principal.team, ...(rec.info.capabilities?.length ? { capabilities: rec.info.capabilities } : {}) },
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
  if (!enrolled.ok) {
    // TeamDO refused in the same commit as the role check and revoked the install; the code is spent.
    if (enrolled.refused) await stub.abort(code, principal.user!, Date.now())
    return fail(op, frame.idempotency_key, enrolled.code, enrolled.message)
  }
  const result: PairingResult = { host: enrolled.host, team, user: principal.user!, install }
  const c = await stub.complete(code, rec.thumbprint, result, Date.now())
  if (!c.ok) return fail(op, frame.idempotency_key, "validation.invalid", c.message)
  return done(result)
}
