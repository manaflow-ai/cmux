import type { Principal } from "@cmux/ownership"
import { authenticate } from "./auth.ts"
import type { AcpmuxRefusal, AcpmuxReply } from "./cloud-acpmux-do.ts"
import { isAcpmuxKeyLine, isAcpmuxNonce } from "./cloud-acpmux-guest.ts"
import type { Env } from "./env.ts"
import { ssoGate } from "./policy-gate.ts"
import { principalForOwner, selectTeam, TEAM_HEADER } from "./team-select.ts"

/**
 * cx-kvmz (cx-0q7o slice 2e): the keyed acpmux start and the person_holds check on a Cloud
 * machine of the app server, as plain HTTP routes OUTSIDE the op path (like /v1/cloud/bind):
 *
 *   POST /v1/cloud/machines/{machine}/acpmux/keyed-start   body: the key line K
 *   POST /v1/cloud/machines/{machine}/acpmux/person-holds  body: {"nonce": "<64 hex>"}
 *
 * The cmux app makes K for one daemon run (#13742 D16) and sends it here only. K is
 * NON-LOGGABLE: the Worker reads it from the body only, hands it to the team's CloudDO as an RPC
 * argument (never an op, so no op-log row, ledger or audit param holds it), and zeroes its own
 * copy after the call. A request that carries a 64-hex run anywhere but the body (the URL, a
 * query, any header) is refused before the body is read, so a key there is never used. That
 * refusal does not keep it out of the invocation log, which records the URL and every header but
 * Authorization: the controls for the log are that the cmux app never puts a key outside the body
 * (CloudOwnerAPIClient) and that staging and production run with invocation logs off
 * (development keeps them on). The keyed-start body must be application/octet-stream with a
 * declared Content-Length of exactly 65 (411 without one): 64 lowercase hex characters and a
 * newline. No console line, error or answer here holds any part of a body. No Idempotency-Key and
 * no retry: a call that did not answer is sent again by the person, with a new key.
 *
 * Auth: a person's session only (a Stack session token; no install token, no agent, no VM
 * install), in its personal team or the team `x-cmux-team` names (TeamDO confirms the
 * membership and the team.resources grant, as on every session route).
 */
export const ACPMUX_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/acpmux\/(keyed-start|person-holds)$/

const KEY_LINE_BYTES = 65
const HOLDS_BODY_MAX = 512
const HEX_RUN = /[0-9a-fA-F]{64}/

const answer = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message } }, { status, headers: { "cache-control": "no-store" } })

const REFUSAL: Readonly<Record<AcpmuxRefusal, [number, string, string]>> = {
  forbidden: [403, "auth.forbidden", "approvals need a person's session"],
  not_found: [404, "cloud.machine.not_found", "no such machine in this team"],
  not_single_owner: [403, "cloud.acpmux.not_single_owner", "approvals work only on a machine you alone own"],
  owner_unconfirmed: [503, "owner.unreachable", "the machine's owner could not be checked; retry"],
  team_vm: [409, "cloud.acpmux.team_vm", "approvals do not work on a team machine"],
  not_running: [409, "cloud.machine.not_running", "the machine is not running"],
  busy: [409, "cloud.acpmux.busy", "a restart with approvals is already running on this machine"],
  unsupported: [409, "cloud.acpmux.unsupported", "this machine's cmux-tui is too old for approvals"],
  timeout: [504, "cloud.acpmux.timeout", "the machine did not answer in time"],
  start_failed: [502, "cloud.acpmux.start_failed", "the agent daemon did not start with approvals"],
  holds_failed: [502, "cloud.acpmux.holds_failed", "the agent daemon did not answer the approvals check"],
  provider_failed: [502, "cloud.provider.unavailable", "the machine could not be reached"],
  bad_request: [400, "validation.invalid", "invalid approvals request"]
}

const reply = <A>(r: AcpmuxReply<A>): Response => {
  if (r.ok) return Response.json({ ok: true, value: r.value }, { headers: { "cache-control": "no-store" } })
  const [status, code, message] = REFUSAL[r.refusal] ?? [502, "cloud.acpmux.start_failed", "approvals failed"]
  return Response.json({ ok: false, error: { code, message, ...(r.line ? { details: { line: r.line } } : {}) } }, { status, headers: { "cache-control": "no-store" } })
}

/** The person's principal for the team's CloudDO, or the refusal answer. */
const sessionFor = async (request: Request, env: Env): Promise<Principal | Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const token = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!token?.user || !token.team) return answer(401, "auth.unauthenticated", "a session token is required")
  if (token.kind !== "session" || token.agent !== undefined || token.install !== undefined) return answer(403, "auth.forbidden", "approvals need a person's session")
  const selected = await selectTeam(env, { ...token, user: token.user, team: token.team }, request.headers.get(TEAM_HEADER))
  if (!selected.ok) return answer(selected.code === "owner.unreachable" ? 503 : 403, selected.code, selected.message)
  const gate = await ssoGate(env, selected.principal).catch(() => null)
  if (!gate) return answer(503, "owner.unreachable", "the sign-in policy could not be checked; retry")
  if (gate.refusal) return answer(403, gate.refusal.code, gate.refusal.message)
  const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
  const granted = await principalForOwner(env, "cloud:CloudDO", authed).catch(() => null)
  if (granted === null) return answer(503, "owner.unreachable", "team membership could not be checked; retry")
  if (!granted || "refused" in granted) return answer(403, "auth.forbidden", "no access to this team's machines")
  return granted
}

/** Reads at most `max` bytes of the body; null once it passes `max` (stops reading there). */
export const readBody = async (request: Request, max: number): Promise<Uint8Array | null> => {
  if (!request.body) return new Uint8Array(0)
  const reader = request.body.getReader()
  const out = new Uint8Array(max)
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (size + value.byteLength > max) {
        value.fill(0)
        await reader.cancel().catch(() => undefined)
        out.fill(0)
        return null
      }
      out.set(value, size)
      size += value.byteLength
      value.fill(0)
    }
  } catch {
    out.fill(0)
    return null
  }
  return out.subarray(0, size)
}

type Stub = {
  acpmuxKeyedStart(entity: string, p: Principal, machine: string, keyLine: Uint8Array): Promise<AcpmuxReply<{ personInstance: string }>>
  acpmuxPersonHolds(entity: string, p: Principal, machine: string, nonce: string): Promise<AcpmuxReply<{ instance: string; proof: string }>>
}

export const handleCloudAcpmux = async (request: Request, env: Env, machine: string, action: "keyed-start" | "person-holds"): Promise<Response> => {
  if (request.method !== "POST") return Response.json({ ok: false, error: { code: "validation.invalid", message: "POST only" } }, { status: 405, headers: { allow: "POST" } })
  const url = new URL(request.url)
  // Rule 1 (hq-84): nothing that looks like a key outside the body, checked before the body is read.
  if (url.search !== "" || HEX_RUN.test(url.pathname)) return answer(400, "validation.invalid", "approvals requests carry no query")
  for (const [, value] of request.headers) if (HEX_RUN.test(value)) return answer(400, "validation.invalid", "approvals requests carry the key in the body only")
  const declared = request.headers.get("content-length")
  if (declared === null) return answer(411, "validation.length_required", "the request did not say its length")
  const type = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase()
  if (action === "keyed-start" && (type !== "application/octet-stream" || declared.trim() !== String(KEY_LINE_BYTES))) return answer(400, "validation.invalid", "the request did not carry one approvals key")
  if (action === "person-holds" && (type !== "application/json" || !(Number(declared) > 0 && Number(declared) <= HOLDS_BODY_MAX))) return answer(400, "validation.invalid", "invalid approvals check")
  // The body is read only for an authenticated person.
  const principal = await sessionFor(request, env)
  if (principal instanceof Response) return principal
  const stub = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(principal.team!)) as unknown as Stub
  if (action === "keyed-start") {
    const keyLine = await readBody(request, KEY_LINE_BYTES)
    try {
      if (!keyLine || !isAcpmuxKeyLine(keyLine)) return answer(400, "validation.invalid", "the request did not carry one approvals key")
      return reply(await stub.acpmuxKeyedStart(principal.team!, principal, machine, keyLine))
    } catch {
      return answer(503, "owner.unreachable", "the Cloud service could not be reached; retry")
    } finally {
      keyLine?.fill(0)
    }
  }
  const raw = await readBody(request, HOLDS_BODY_MAX)
  let nonce: unknown
  try {
    nonce = raw ? (JSON.parse(new TextDecoder().decode(raw)) as { nonce?: unknown } | null)?.nonce : undefined
  } catch {
    nonce = undefined
  }
  if (!isAcpmuxNonce(nonce)) return answer(400, "validation.invalid", "the approvals check needs a nonce of 64 lowercase hex characters")
  try {
    return reply(await stub.acpmuxPersonHolds(principal.team!, principal, machine, nonce))
  } catch {
    return answer(503, "owner.unreachable", "the Cloud service could not be reached; retry")
  }
}
