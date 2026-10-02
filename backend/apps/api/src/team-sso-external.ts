import type { OwnerFrame, Principal, RejectFrame, ResultFrame } from "@cmux/ownership"
import { SsoConnectionActivate, SsoConnectionSetSecret } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import type { TeamState } from "./domains/team.ts"
import { open, seal, type SealedSecret } from "./integrations/crypto.ts"
import type { DomainReply, Http } from "./team-domain-external.ts"

const enc = new TextEncoder()
/** Binds a sealed client secret to its team, connection and generation. */
const aad = (team: string, connection: string, generation: number) => enc.encode(`cmux-sso-v1|${team}|${connection}|${generation}`)

export interface SsoExternalDeps {
  readonly state: TeamState
  readonly team: string
  readonly stream: string
  readonly http: Http
  readonly kek: string | undefined
  readonly sql: SqlStorage
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

export const ensureSecretTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS sso_secrets (connection TEXT PRIMARY KEY, generation INTEGER NOT NULL, sealed TEXT NOT NULL)`)

/** The connection's client secret (callback, slice 2c-2b). */
export const openClientSecret = async (deps: Pick<SsoExternalDeps, "team" | "kek" | "sql">, connection: string): Promise<string | undefined> => {
  if (!deps.kek) return undefined
  ensureSecretTable(deps.sql)
  const row = deps.sql.exec<{ generation: number; sealed: string }>(`SELECT generation, sealed FROM sso_secrets WHERE connection = ?`, connection).toArray()[0]
  return row ? open(deps.kek, JSON.parse(row.sealed) as SealedSecret, aad(deps.team, connection, Number(row.generation))) : undefined
}

/** Fields an OpenID Provider discovery document must carry, all https. */
const discovery = async (http: Http, issuer: string) => {
  const res = await http(new Request(`${issuer}/.well-known/openid-configuration`, { headers: { accept: "application/json" } }))
  if (!res.ok) throw new Error(`discovery returned ${res.status}`)
  const doc = (await res.json()) as Record<string, unknown>
  // OpenID Connect Discovery 1.0 section 4.3: the issuer must equal the configured one exactly.
  if (doc.issuer !== issuer) throw new Error(`discovery issuer ${String(doc.issuer)} differs from ${issuer}`)
  const url = (k: string) => {
    const v = doc[k]
    if (typeof v !== "string" || !v.startsWith("https://")) throw new Error(`discovery ${k} missing or not https`)
    return v
  }
  return { authorization_endpoint: url("authorization_endpoint"), token_endpoint: url("token_endpoint"), jwks_uri: url("jwks_uri") }
}

/**
 * sso.connection.set_secret and sso.connection.activate. The secret travels
 * only in this request (never an op param, event or snapshot) and is sealed
 * with INTEGRATIONS_KEK. Owners and admins with a session; agents refused.
 */
export const ssoExternal = async (deps: SsoExternalDeps, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  const role = principal.user ? deps.state.members[principal.user]?.role : undefined
  if (principal.kind !== "session" || principal.agent) return fail("auth.forbidden", "SSO changes need a person's session")
  if (role !== "owner" && role !== "admin") return fail("auth.forbidden", "only team owners and admins may change SSO connections")
  const commit = (op: string, params: unknown, key: string): DomainReply => {
    const { frames } = deps.submitSystem(op, params, key)
    const rej = frames.find((f): f is RejectFrame => f.t === "reject")
    if (rej) return fail(rej.code, rej.message)
    const res = frames.find((f): f is ResultFrame => f.t === "result")!
    const settled = frames.find((f) => f.t === "request-settled") as { sequence?: number } | undefined
    return { ...base, ok: true, value: res.value, transaction: res.tx, replayed: res.replayed, sequence: settled?.sequence ?? 0 }
  }
  const by = principal.user ?? principal.identity

  if (frame.op === "sso.connection.set_secret") {
    const d = decodeParams<{ connection: string; client_secret: string }>(SsoConnectionSetSecret, frame.params)
    if (!d.ok) return fail(d.code, d.message)
    if (!deps.state.sso_connections?.[d.value.connection]) return fail("selector.not_found", "connection not found")
    if (!deps.kek) return fail("sso.not_configured", "SSO secrets need INTEGRATIONS_KEK on this deployment")
    ensureSecretTable(deps.sql)
    const prev = deps.sql.exec<{ generation: number }>(`SELECT generation FROM sso_secrets WHERE connection = ?`, d.value.connection).toArray()[0]
    const generation = Number(prev?.generation ?? 0) + 1
    const sealed = await seal(deps.kek, d.value.client_secret, aad(deps.team, d.value.connection, generation))
    deps.sql.exec(
      `INSERT INTO sso_secrets (connection, generation, sealed) VALUES (?, ?, ?) ON CONFLICT (connection) DO UPDATE SET generation = excluded.generation, sealed = excluded.sealed`,
      d.value.connection,
      generation,
      JSON.stringify(sealed)
    )
    return commit("sso.connection.secret_set", { connection: d.value.connection, generation, by }, `sso-secret:${d.value.connection}:${generation}`)
  }

  const d = decodeParams<{ connection: string }>(SsoConnectionActivate, frame.params)
  if (!d.ok) return fail(d.code, d.message)
  const c = deps.state.sso_connections?.[d.value.connection]
  if (!c) return fail("selector.not_found", "connection not found")
  if (c.state === "active") return { ...base, ok: true, value: c }
  let endpoints: Awaited<ReturnType<typeof discovery>>
  try {
    endpoints = await discovery(deps.http, c.oidc.issuer)
  } catch (e) {
    return fail("sso.discovery_failed", String(e instanceof Error ? e.message : e), true)
  }
  return commit("sso.connection.activated", { connection: c.id, ...endpoints, by }, `sso-activated:${c.id}:${c.updated_at}`)
}
