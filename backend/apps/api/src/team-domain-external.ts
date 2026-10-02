import type { OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { DomainRelease, DomainVerify } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { txtContains } from "./domains/team-domains.ts"
import type { TeamState } from "./domains/team.ts"
import type { DomainDO } from "./domain-do.ts"

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

/** TXT strings for `name` from one DNS-over-HTTPS resolver (empty on any failure). */
const txtAnswers = async (http: Http, request: Request): Promise<Array<string>> => {
  try {
    const res = await http(request)
    if (!res.ok) return []
    const body = (await res.json()) as { Status?: number; Answer?: Array<{ type?: number; data?: string }> }
    if (body.Status !== 0) return []
    return (body.Answer ?? []).filter((a) => a.type === 16 && typeof a.data === "string").map((a) => a.data!)
  } catch {
    return []
  }
}

export interface DomainExternalDeps {
  readonly state: TeamState
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
  const role = principal.user ? deps.state.members[principal.user]?.role : undefined
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

  if (frame.op === "domain.release") {
    if (claim.state === "verified") await deps.domainStub(domain).release(deps.team)
    return commit("domain.mark_released", { domain }, `domain-released:${domain}:${claim.record_value}`)
  }

  if (claim.state === "verified") return { ...base, ok: true, value: claim }
  if (claim.expires_at <= deps.now) return fail("domain.not_verified", "the claim expired; claim the domain again for a new record")
  const results = await Promise.all(RESOLVERS.map((r) => txtAnswers(deps.http, r(claim.record_name))))
  if (!results.every((answers) => txtContains(answers, claim.record_value))) {
    return fail("domain.not_verified", `both resolvers must see TXT ${claim.record_name} = ${claim.record_value}; DNS can take minutes to propagate`, true)
  }
  const owned = await deps.domainStub(domain).claim(domain, deps.team, deps.now)
  if (!owned.ok) return fail("domain.taken", `${domain} is verified by another team`)
  return commit("domain.mark_verified", { domain, record_value: claim.record_value, verified_at: owned.verified_at }, `domain-verified:${domain}:${claim.record_value}`)
}
