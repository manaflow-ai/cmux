import type { Principal } from "@cmux/ownership"
import { DurableObject } from "cloudflare:workers"
import { authenticate } from "./auth.ts"
import type { Env } from "./env.ts"
import { isMachineInstallKind } from "./machine-installs.ts"

/**
 * Wire credentials (bead cx-dgsp). Workers invocation logs record every request header except
 * Authorization, so a token in Sec-WebSocket-Protocol is logged. A wire upgrade takes its
 * credential from one of these, in this order:
 *
 * 1. `Authorization: Bearer <token>`: native clients (URLSession, tungstenite) set it on the upgrade.
 * 2. Subprotocol `ticket.<ticket>`: browsers, which cannot set headers. POST /v1/wire/ticket with
 *    the Authorization header mints the ticket: 32 random bytes, single use, 30 s, 60 per minute
 *    per user, bound to the socket scope its body names (`{scope}`, default `user`). The router
 *    entry spends it on any path, before any other check, so a ticket in a log is always spent;
 *    a ticket opens only a socket of its own scope.
 *
 * The legacy `bearer.<token>` subprotocol is retired: it authenticates nothing, and it is still
 * stripped from the subprotocols forwarded to the owner object, so a token never travels further.
 */

export const TICKET_PREFIX = "ticket."
/** The retired credential subprotocol: never read, always stripped. */
const RETIRED_PREFIX = "bearer."
/** A ticket lives 30 s: a client mints it and upgrades at once; 30 s covers slow cellular and TLS. */
export const WIRE_TICKET_TTL_MS = 30_000
/** Each 401 from a wire upgrade names this header, so a native client knows the server reads Authorization. */
export const WIRE_AUTH_HEADER = "x-cmux-wire-auth"
export const WIRE_AUTH_VALUE = "authorization, ticket"
/** The socket scopes a ticket can be minted for: the `/v1/wire/<scope>` routes (index.ts). */
export const WIRE_SCOPES = ["user", "team", "feed", "cloud", "conv", "mux"] as const
export type WireScope = (typeof WIRE_SCOPES)[number]
const TICKET_SHARDS = 256
const TICKET_SHAPE = /^[A-Za-z0-9_-]{43}$/

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const sha256 = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))
const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

interface TicketRecord {
  readonly principal: Principal
  readonly expires_at: number
  /** Absent on a ticket minted before tickets were bound (a 30 s window at deploy): a user ticket. */
  readonly scope?: WireScope
}

/**
 * WireTicketDO: 256 shards (the first byte of SHA-256(ticket)). The storage key is the hash, so
 * storage never holds a usable ticket. `spend` reads and deletes in one turn of the object, so
 * one ticket opens at most one socket. The alarm deletes tickets that were never spent.
 */
export class WireTicketDO extends DurableObject<Env> {
  async put(key: string, record: TicketRecord): Promise<void> {
    await this.ctx.storage.put(key, record)
    const alarm = await this.ctx.storage.getAlarm()
    if (alarm === null || alarm > record.expires_at) await this.ctx.storage.setAlarm(record.expires_at)
  }

  async spend(key: string, now: number): Promise<{ principal: Principal; scope: WireScope } | null> {
    const record = await this.ctx.storage.get<TicketRecord>(key)
    if (!record) return null
    await this.ctx.storage.delete(key)
    return record.expires_at > now ? { principal: record.principal, scope: record.scope ?? "user" } : null
  }

  override async alarm(): Promise<void> {
    const now = Date.now()
    const all = await this.ctx.storage.list<TicketRecord>()
    const expired: Array<string> = []
    let next: number | undefined
    for (const [k, r] of all) {
      if (r.expires_at <= now) expired.push(k)
      else next = next === undefined ? r.expires_at : Math.min(next, r.expires_at)
    }
    for (let i = 0; i < expired.length; i += 128) await this.ctx.storage.delete(expired.slice(i, i + 128))
    if (next !== undefined) await this.ctx.storage.setAlarm(next)
  }
}

const shardOf = async (env: Env, ticket: string) => {
  const digest = await sha256(ticket)
  const ns = env.WIRE_TICKET_DO
  return { stub: ns.get(ns.idFromName(`wire-ticket:${digest[0]! % TICKET_SHARDS}`)), key: hex(digest) }
}

const bearerOf = (request: Request) => {
  const auth = request.headers.get("authorization") ?? ""
  return auth.startsWith("Bearer ") ? auth.slice(7).trim() || undefined : undefined
}

const unauthenticated = (message: string) =>
  Response.json({ error: { code: "auth.unauthenticated", message } }, { status: 401, headers: { [WIRE_AUTH_HEADER]: WIRE_AUTH_VALUE } })

/** The scope a mint request names: its JSON body's `scope`, `user` for no body; undefined for any other. */
const requestedScope = async (request: Request): Promise<WireScope | undefined> => {
  const text = await request.text()
  if (!text.trim()) return "user"
  let scope: unknown
  try {
    scope = (JSON.parse(text) as { scope?: unknown } | null)?.scope ?? "user"
  } catch {
    return undefined
  }
  return WIRE_SCOPES.find((s) => s === scope)
}

/** POST /v1/wire/ticket with `Authorization: Bearer <token>` and `{scope}`: `{ticket, expires_at}` for one upgrade of that scope. */
export const handleWireTicket = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "POST") return Response.json({ error: { code: "method_not_allowed", message: "POST only" } }, { status: 405 })
  const scope = await requestedScope(request)
  if (scope === undefined) return Response.json({ error: { code: "invalid_request", message: `scope is one of ${WIRE_SCOPES.join(", ")}` } }, { status: 400 })
  const principal = await authenticate(env, bearerOf(request))
  if (!principal?.user || !principal.team) return unauthenticated("bearer token required")
  if (isMachineInstallKind(principal.install_kind)) return Response.json({ error: { code: "auth.forbidden", message: "a VM install has no socket" } }, { status: 403 })
  const limit = env.WIRE_TICKET_LIMIT
  if (limit && !(await limit.limit({ key: principal.user })).success)
    return Response.json({ error: { code: "auth.rate_limited", message: "too many wire tickets; retry in a minute" } }, { status: 429, headers: { "retry-after": "60" } })
  const now = Date.now()
  const expires_at = Math.min(now + WIRE_TICKET_TTL_MS, principal.expires_at ?? Number.POSITIVE_INFINITY)
  if (expires_at <= now) return unauthenticated("token expired")
  const ticket = b64u(crypto.getRandomValues(new Uint8Array(32)))
  const { stub, key } = await shardOf(env, ticket)
  await stub.put(key, { principal, expires_at, scope })
  return Response.json({ ticket, expires_at, scope }, { headers: { "cache-control": "no-store" } })
}

export type WireCredential = { readonly ok: true; readonly principal: Principal | undefined; readonly protocols: ReadonlyArray<string> } | { readonly ok: false; readonly response: Response }

/** A ticket spent at the router entry: the principal and scope it carried, or a null principal for an unknown, spent or expired ticket. */
export type SpentTicket = { readonly principal: Principal | null; readonly scope?: WireScope }

const subprotocols = (request: Request) => (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim()).filter(Boolean)

/**
 * Spends a `ticket.` subprotocol at the router entry, whatever the path, so a ticket that reaches
 * any route (an unrouted one too) is spent by that request. Undefined when the request has none.
 */
export const spendTicketAtEntry = async (request: Request, env: Env): Promise<SpentTicket | undefined> => {
  const ticket = subprotocols(request).find((p) => p.startsWith(TICKET_PREFIX))?.slice(TICKET_PREFIX.length)
  if (ticket === undefined) return undefined
  if (!TICKET_SHAPE.test(ticket)) return { principal: null }
  const { stub, key } = await shardOf(env, ticket)
  const spent = await stub.spend(key, Date.now())
  // The ticket outlives no token: a principal past its expiry opens nothing.
  if (!spent || (spent.principal.expires_at !== undefined && spent.principal.expires_at <= Date.now())) return { principal: null }
  return spent
}

/**
 * Resolves the upgrade's principal and returns the subprotocols without any credential, so the
 * request forwarded to the owner object carries none. `spent` is the router entry's ticket result;
 * a ticket of another scope than the route's opens nothing (it is spent all the same).
 */
export const wireCredential = async (request: Request, env: Env, spent: SpentTicket | undefined, scope: WireScope): Promise<WireCredential> => {
  const all = subprotocols(request)
  const protocols = all.filter((p) => !p.startsWith(TICKET_PREFIX) && !p.startsWith(RETIRED_PREFIX))
  if (spent !== undefined) {
    if (!spent.principal) return { ok: false, response: unauthenticated("unknown or spent ticket") }
    if (spent.scope !== scope) return { ok: false, response: unauthenticated(`ticket minted for the ${spent.scope} socket`) }
    return { ok: true, principal: spent.principal, protocols }
  }
  const header = bearerOf(request)
  return { ok: true, principal: header === undefined ? undefined : await authenticate(env, header), protocols }
}

/** The forwarded upgrade: the request's headers without Authorization and with credential-free subprotocols. */
export const forwardHeaders = (request: Request, protocols: ReadonlyArray<string>): Headers => {
  const headers = new Headers(request.headers)
  headers.delete("authorization")
  if (protocols.length) headers.set("Sec-WebSocket-Protocol", protocols.join(", "))
  else headers.delete("Sec-WebSocket-Protocol")
  return headers
}

export const wireUnauthenticated = () => unauthenticated("unauthenticated")
