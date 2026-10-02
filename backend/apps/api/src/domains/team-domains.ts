import type { Reject, ReduceContext } from "@cmux/ownership"
import { DomainClaim, type TeamDomain } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"

/**
 * Email domain claims of a team (spec/enterprise.md 3.4). TeamDO holds the
 * team's view (pending claims, the TXT value, verified state); the domain's
 * DomainDO is the single writer of which team owns it. Verification itself
 * (DNS over HTTPS, then DomainDO) runs in TeamDO.domainExternal, which commits
 * domain.mark_verified / domain.mark_released here.
 */
export type Domain = typeof TeamDomain.Type

export interface DomainState {
  readonly domains?: Readonly<Record<string, Domain>>
}

export const PENDING_DAYS = 14
export const MAX_DOMAINS = 20
export const RECORD_PREFIX = "_cmux-challenge"

/**
 * Mail domains anyone can sign up at: never claimable, or one team could
 * route every user of that provider to its IdP.
 */
export const PUBLIC_MAIL_DOMAINS: ReadonlySet<string> = new Set([
  "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com", "icloud.com", "me.com",
  "mac.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net", "gmx.de", "web.de", "mail.com", "yandex.com",
  "yandex.ru", "mail.ru", "qq.com", "163.com", "126.com", "zoho.com", "fastmail.com", "hey.com", "tutanota.com", "duck.com", "naver.com"
])

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & Reject)

export const recordName = (domain: string) => `${RECORD_PREFIX}.${domain}`

/** domain.claim: a new TXT value, or the current one while the claim is pending. */
export const reduceDomainClaim = <S extends DomainState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof DomainClaim.params.Type>(DomainClaim, params)
  if (!d.ok) return d
  const domain = d.value.domain
  if (PUBLIC_MAIL_DOMAINS.has(domain)) return reject("policy.invalid", `${domain} is a public mail domain and cannot be claimed`)
  const existing = state.domains?.[domain]
  if (existing?.state === "verified") return { ok: true, state, value: existing, changed: false }
  if (existing && existing.expires_at > ctx.now) return { ok: true, state, value: existing, changed: false }
  if (!existing && Object.keys(state.domains ?? {}).length >= MAX_DOMAINS) return reject("policy.invalid", `at most ${MAX_DOMAINS} domains per team`)
  const claim: Domain = {
    domain,
    state: "pending",
    record_name: recordName(domain),
    record_value: `cmux-verification=${ctx.newId("dvt")}`,
    requested_at: ctx.now,
    expires_at: ctx.now + PENDING_DAYS * 86_400_000,
    verified_at: null
  }
  return {
    ok: true,
    state: { ...state, domains: { ...state.domains, [domain]: claim } },
    value: claim,
    audit: { summary: `claimed ${domain}`, detail: { domain, record_name: claim.record_name } }
  }
}

/** System op domain.mark_verified {domain, record_value, verified_at}: DomainDO accepted the team. */
export const reduceDomainVerified = <S extends DomainState>(state: S, params: unknown): Result<S> => {
  const p = params as { domain?: unknown; record_value?: unknown; verified_at?: unknown; by?: unknown }
  const claim = typeof p?.domain === "string" ? state.domains?.[p.domain] : undefined
  if (!claim) return reject("selector.not_found", "no claim for this domain")
  // Only the value that was checked: a newer claim's value must be checked on its own.
  if (claim.record_value !== p.record_value) return reject("validation.invalid", "the claim changed while it was being verified")
  if (claim.state === "verified") return { ok: true, state, value: claim, changed: false }
  const verified: Domain = { ...claim, state: "verified", verified_at: typeof p.verified_at === "number" ? p.verified_at : claim.requested_at }
  return {
    ok: true,
    state: { ...state, domains: { ...state.domains, [claim.domain]: verified } },
    value: verified,
    audit: { summary: `verified ${claim.domain}`, detail: { domain: claim.domain, by: typeof p.by === "string" ? p.by : null } }
  }
}

/** System op domain.mark_lost {domain}: DomainDO refused a re-check (another team owns it now). */
export const reduceDomainLost = <S extends DomainState>(state: S, params: unknown): Result<S> => {
  const domain = (params as { domain?: unknown })?.domain
  const claim = typeof domain === "string" ? state.domains?.[domain] : undefined
  if (!claim || claim.state === "lost") return { ok: true, state, value: claim ?? null, changed: false }
  const lost: Domain = { ...claim, state: "lost" }
  return { ok: true, state: { ...state, domains: { ...state.domains, [claim.domain]: lost } }, value: lost, audit: { summary: `lost ${claim.domain}`, detail: { domain: claim.domain } } }
}

/** System op domain.mark_released {domain}: DomainDO dropped the team's claim. */
export const reduceDomainReleased = <S extends DomainState>(state: S, params: unknown): Result<S> => {
  const p = params as { domain?: unknown; by?: unknown }
  const domain = p?.domain
  if (typeof domain !== "string" || !state.domains?.[domain]) return { ok: true, state, value: { domain }, changed: false }
  const { [domain]: _gone, ...rest } = state.domains
  return { ok: true, state: { ...state, domains: rest }, value: { domain }, audit: { summary: `released ${domain}`, detail: { domain, by: typeof p.by === "string" ? p.by : null } } }
}

/** True when both resolvers' TXT answers for the record contain the value. */
export const txtContains = (answers: ReadonlyArray<string>, value: string) =>
  answers.some((a) => a.replace(/^"|"$/g, "").replace(/"\s*"/g, "") === value)
