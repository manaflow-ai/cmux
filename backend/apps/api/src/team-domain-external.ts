import type { OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { DomainRelease, DomainVerify } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { txtContains } from "./domains/team-domains.ts"
import type { TeamState } from "./domains/team.ts"
import type { DomainDO } from "./domain-do.ts"
import type { RowReader } from "@cmux/ownership"
import { hostByInstall, memberOf, roleOf } from "./domains/team-members.ts"

export type Http = (request: Request) => Promise<Response>

export interface DomainReply {
  readonly ok: boolean
  readonly op: string
  readonly value?: unknown
  readonly error?: { readonly code: string; readonly message: string; readonly retryable: boolean }
  readonly transaction: string
  readonly idempotency_key: string
  readonly replayed: boolean
  readonly stream: string
  readonly sequence: number
}

/** Two independent resolvers must both see the record (spec/enterprise.md 3.4). */
export const RESOLVERS = [
  (name: string) => new Request(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=TXT`, { headers: { accept: "application/dns-json" } }),
  (name: string) => new Request(`https://dns.google/resolve?name=${encodeURIComponent(name)}&type=TXT`, { headers: { accept: "application/dns-json" } })
]

/** TXT strings for `name` from one DNS-over-HTTPS resolver; null when the resolver failed (unknown, not "missing"). */
export const txtAnswers = async (http: Http, request: Request): Promise<Array<string> | null> => {
  try {
    const res = await http(request)
    if (!res.ok) return null
    const body = (await res.json()) as { Status?: number; Answer?: Array<{ name?: string; type?: number; data?: string }> }
    // NXDOMAIN (3) is a real "no record"; other statuses are resolver trouble.
    if (body.Status === 3) return []
    if (body.Status !== 0) return null
    // Only TXT records of the exact name: an answer reached through a CNAME (for example a wildcard
    // or dangling record pointing elsewhere) would let whoever controls the target verify.
    const want = new URL(request.url).searchParams.get("name")!.toLowerCase().replace(/\.$/, "")
    return (body.Answer ?? [])
      .filter((a) => a.type === 16 && typeof a.data === "string" && (a.name ?? "").toLowerCase().replace(/\.$/, "") === want)
      .map((a) => a.data!)
  } catch {
    return null
  }
}

export interface DomainExternalDeps {
  readonly state: TeamState
  /** TeamDO rows (members and hosts, team-members.ts). */
  readonly rows?: RowReader
  readonly team: string
  readonly stream: string
  readonly http: Http
  readonly domainStub: (domain: string) => DurableObjectStub<DomainDO>
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
  readonly now: number
}

/**
 * domain.verify and domain.release: external effects (DNS over HTTPS, the
 * domain's DomainDO) run here, then TeamDO commits the outcome as a system op
 * with an audit record. Owners and admins only; agents are refused.
 */
export const domainExternal = async (
  deps: DomainExternalDeps,
  principal: Principal,
  frame: { op: string; params: unknown; idempotency_key: string }
): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const role = roleOf(deps.state, deps.rows, principal.user)
  if (principal.kind !== "session" || principal.agent) return fail("auth.forbidden", "domain changes need a person's session")
  if (role !== "owner" && role !== "admin") return fail("auth.forbidden", "only team owners and admins may verify or release domains")
  const decoded = decodeParams<{ domain: string }>(frame.op === "domain.verify" ? DomainVerify : DomainRelease, frame.params)
  if (!decoded.ok) return fail(decoded.code, decoded.message)
  const domain = decoded.value.domain
  const claim = deps.state.domains?.[domain]
  if (!claim) return fail("selector.not_found", `no claim for ${domain}`)

  const commit = (op: string, params: unknown, key: string): DomainReply => {
    const { frames } = deps.submitSystem(op, params, key)
    const rej = frames.find((f): f is RejectFrame => f.t === "reject")
    if (rej) return fail(rej.code, rej.message)
    const res = frames.find((f): f is ResultFrame => f.t === "result")!
    const settled = frames.find((f) => f.t === "request-settled") as { sequence?: number } | undefined
    return { ...base, ok: true, value: res.value, transaction: res.tx, replayed: res.replayed, sequence: settled?.sequence ?? 0 }
  }

  const by = principal.user ?? principal.identity
  if (frame.op === "domain.release") {
    // Always, whatever TeamDO's state says: release is scoped to this team and idempotent.
    await deps.domainStub(domain).release(deps.team)
    return commit("domain.mark_released", { domain, by }, `domain-released:${domain}:${claim.record_value}`)
  }

  // A verified claim is re-checked against DomainDO (the single writer), never trusted from TeamDO alone.
  if (claim.state === "verified" || claim.state === "lost") {
    const held = await deps.domainStub(domain).claim(domain, deps.team, deps.now)
    if (held.ok && claim.state === "verified") return { ...base, ok: true, value: claim }
    if (!held.ok) return claim.state === "lost" ? fail("domain.taken", `${domain} is verified by another team`) : commit("domain.mark_lost", { domain }, `domain-lost:${domain}:${claim.record_value}`)
  }
  if (claim.expires_at <= deps.now && claim.state === "pending") return fail("domain.not_verified", "the claim expired; claim the domain again for a new record")
  const results = await Promise.all(RESOLVERS.map((r) => txtAnswers(deps.http, r(claim.record_name))))
  if (!results.every((answers) => answers !== null && txtContains(answers, claim.record_value))) {
    return fail("domain.not_verified", `both resolvers must see TXT ${claim.record_name} = ${claim.record_value}; DNS can take minutes to propagate`, true)
  }
  const owned = await deps.domainStub(domain).claim(domain, deps.team, deps.now)
  if (!owned.ok) return fail("domain.taken", `${domain} is verified by another team`)
  const reply = commit("domain.mark_verified", { domain, record_value: claim.record_value, verified_at: owned.verified_at, by }, `domain-verified:${domain}:${claim.record_value}:${claim.state}:${claim.last_checked_at ?? 0}`)
  // The claim changed while DNS was checked (released, or re-claimed with a new value): undo DomainDO,
  // so it never owns a domain TeamDO does not claim (review P1-a).
  if (!reply.ok) await deps.domainStub(domain).release(deps.team)
  return reply
}
