import type { Reject, ReduceContext } from "@cmux/ownership"
import { SsoConnectionCreate, SsoConnectionDisable, type SsoConnection } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import type { DomainState } from "./team-domains.ts"

/**
 * Enterprise SSO connections of a team (spec/enterprise.md 3.2), slice 2c-2:
 * OIDC. TeamDO is the single writer. Effects that leave the reducer (sealing
 * the client secret, fetching the issuer's discovery document) run in
 * team-sso-external.ts and commit their outcome through system ops here.
 */
export type Connection = typeof SsoConnection.Type

export interface SsoState extends DomainState {
  readonly sso_connections?: Readonly<Record<string, Connection>>
}

export const MAX_CONNECTIONS = 10

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & Reject)

const put = <S extends SsoState>(state: S, c: Connection): S => ({ ...state, sso_connections: { ...state.sso_connections, [c.id]: c } })

/** A domain may route to one active connection of the team at a time. */
const domainTaken = (state: SsoState, domain: string, except: string) =>
  Object.values(state.sso_connections ?? {}).some((c) => c.id !== except && c.state === "active" && c.domains.includes(domain))

export const reduceConnectionCreate = <S extends SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof SsoConnectionCreate.params.Type>(SsoConnectionCreate, params)
  if (!d.ok) return d
  if (Object.keys(state.sso_connections ?? {}).length >= MAX_CONNECTIONS) return reject("policy.invalid", `at most ${MAX_CONNECTIONS} SSO connections per team`)
  const domains = [...new Set(d.value.domains)].sort()
  const unknown = domains.filter((x) => !state.domains?.[x])
  if (unknown.length > 0) return reject("policy.invalid", `claim these domains first: ${unknown.join(", ")}`)
  const issuer = d.value.issuer.replace(/\/+$/, "")
  const c: Connection = {
    id: ctx.newId("ssoc"),
    kind: "oidc",
    state: "draft",
    domains,
    oidc: { issuer, client_id: d.value.client_id, scopes: [...new Set(["openid", "email", "profile", ...(d.value.scopes ?? [])])], authorization_endpoint: null, token_endpoint: null, jwks_uri: null },
    secret_set: false,
    jit: d.value.jit ?? { enabled: true, default_role: "member" },
    created_at: ctx.now,
    updated_at: ctx.now
  }
  return { ok: true, state: put(state, c), value: c, audit: { summary: `created OIDC connection ${c.id}`, detail: { connection: c.id, issuer, client_id: c.oidc.client_id, domains } } }
}

export const reduceConnectionDisable = <S extends SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof SsoConnectionDisable.params.Type>(SsoConnectionDisable, params)
  if (!d.ok) return d
  const c = state.sso_connections?.[d.value.connection]
  if (!c) return reject("selector.not_found", "connection not found")
  if (c.state === "disabled") return { ok: true, state, value: c, changed: false }
  const next = { ...c, state: "disabled" as const, updated_at: ctx.now }
  return { ok: true, state: put(state, next), value: next, audit: { summary: `disabled SSO connection ${c.id}`, detail: { connection: c.id } } }
}

/** System op sso.connection.secret_set {connection, generation}: the secret is sealed (never in params). */
export const reduceSecretSet = <S extends SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const p = params as { connection?: unknown; generation?: unknown; by?: unknown }
  const c = typeof p?.connection === "string" ? state.sso_connections?.[p.connection] : undefined
  if (!c) return reject("selector.not_found", "connection not found")
  const next = { ...c, secret_set: true, updated_at: ctx.now }
  return { ok: true, state: put(state, next), value: next, audit: { summary: `set the client secret of ${c.id}`, detail: { connection: c.id, generation: p.generation, by: p.by ?? null } } }
}

/** System op sso.connection.activated {connection, endpoints}: discovery succeeded and every precondition held. */
export const reduceActivated = <S extends SsoState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const p = params as { connection?: unknown; authorization_endpoint?: string; token_endpoint?: string; jwks_uri?: string; by?: unknown }
  const c = typeof p?.connection === "string" ? state.sso_connections?.[p.connection] : undefined
  if (!c) return reject("selector.not_found", "connection not found")
  // Rechecked in the commit: state may have changed while discovery was fetched.
  if (!c.secret_set) return reject("policy.invalid", "set the client secret first")
  const unverified = c.domains.filter((x) => state.domains?.[x]?.state !== "verified")
  if (unverified.length > 0) return reject("policy.invalid", `verify these domains first: ${unverified.join(", ")}`)
  const clash = c.domains.filter((x) => domainTaken(state, x, c.id))
  if (clash.length > 0) return reject("policy.invalid", `another active connection already serves: ${clash.join(", ")}`)
  if (!p.authorization_endpoint || !p.token_endpoint || !p.jwks_uri) return reject("validation.invalid", "discovery endpoints missing")
  const next: Connection = {
    ...c,
    state: "active",
    oidc: { ...c.oidc, authorization_endpoint: p.authorization_endpoint, token_endpoint: p.token_endpoint, jwks_uri: p.jwks_uri },
    updated_at: ctx.now
  }
  return { ok: true, state: put(state, next), value: next, audit: { summary: `activated SSO connection ${c.id}`, detail: { connection: c.id, domains: c.domains, by: p.by ?? null } } }
}

/** The active connection serving `domain`, if this team has one (sign-in discovery). */
export const connectionForDomain = (state: SsoState, domain: string): Connection | undefined =>
  state.domains?.[domain]?.state === "verified"
    ? Object.values(state.sso_connections ?? {}).find((c) => c.state === "active" && c.domains.includes(domain))
    : undefined
