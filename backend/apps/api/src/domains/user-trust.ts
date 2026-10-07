import type { Domain, Principal, ReduceResult } from "@cmux/ownership"
import { reject } from "./common.ts"
import { parseLinkCert, STORED_PURPOSES, type LinkCert } from "./link-cert.ts"

/**
 * `trust:<user>`: the account's trust store (plans/cmux-next/ios-next/b6-pairing.md sections 1 and
 * 6). A UserDO secondary stream. Every write is a system op: UserDO's pairing handlers
 * (user-trust-ops.ts) verify signatures, roles and offers first, then commit here, so the reducer
 * only checks shapes, limits and consistency. Never holds a private key, a token or an offer code.
 */

export interface PublicJwk {
  readonly kty: "EC"
  readonly crv: "P-256"
  readonly x: string
  readonly y: string
}

/** One of this user's installs that published link keys. */
export interface TrustDevice {
  readonly install: string
  readonly kind: string
  readonly name: string
  readonly platform: string
  readonly public_jwk: PublicJwk
  /** The host this install enrolled (a Mac), confirmed with TeamDO at publish. */
  readonly host?: string
  readonly certs: Readonly<Partial<Record<"direct" | "wg", LinkCert>>>
  readonly updated_at: number
}

/** The other account's device in a request or a guest grant. */
export interface TrustPeerDevice {
  readonly install: string
  readonly user: string
  readonly user_name: string
  readonly name: string
  readonly platform: string
  readonly public_jwk: PublicJwk
  readonly cert: LinkCert
}

export interface TrustRequest extends TrustPeerDevice {
  /** base64url SHA-256 of the offer code; the code itself never enters the stream. */
  readonly offer_id: string
  readonly host: string
  readonly host_name: string
  readonly team: string
  readonly at: number
  readonly expires_at: number
}

export interface TrustGuest extends TrustPeerDevice {
  readonly offer_id: string
  readonly host: string
  readonly team: string
  readonly accepted_at: number
}

/** Another account's host one of this user's devices was accepted on. */
export interface TrustRemote {
  readonly host: string
  readonly team: string
  readonly owner_user: string
  readonly name: string
  readonly host_install: string
  readonly public_jwk: PublicJwk
  readonly cert: LinkCert
  /** This user's device the owner accepted. */
  readonly install: string
  readonly offer_id: string
  readonly accepted_at: number
}

export interface TrustState {
  readonly devices: Readonly<Record<string, TrustDevice>>
  /** Keyed `<host>/<install>`. */
  readonly guests: Readonly<Record<string, TrustGuest>>
  /** Keyed by offer id. */
  readonly requests: Readonly<Record<string, TrustRequest>>
  /** Keyed `<host>/<install>`. */
  readonly remote: Readonly<Record<string, TrustRemote>>
}

export const MAX_TRUST_DEVICES = 64
export const MAX_TRUST_GUESTS = 256
export const MAX_TRUST_REQUESTS = 32
export const MAX_TRUST_REMOTE = 256

export const pairKey = (host: string, install: string) => `${host}/${install}`

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
const ID = /^[A-Za-z0-9_]{3,80}$/
const B64U = /^[A-Za-z0-9_-]{43}$/
const str = (v: unknown, max = 200): v is string => typeof v === "string" && v.length >= 1 && v.length <= max
const jwkOf = (v: unknown): PublicJwk | undefined =>
  isObj(v) && v.kty === "EC" && v.crv === "P-256" && typeof v.x === "string" && B64U.test(v.x) && typeof v.y === "string" && B64U.test(v.y) ? { kty: "EC", crv: "P-256", x: v.x, y: v.y } : undefined

const peerOf = (p: Record<string, unknown>): TrustPeerDevice | string => {
  const cert = parseLinkCert(p.cert)
  if (typeof cert === "string") return cert
  const jwk = jwkOf(p.public_jwk)
  if (!jwk) return "public_jwk must be a P-256 JWK"
  if (!str(p.install, 80) || !ID.test(p.install) || !str(p.user, 80) || !ID.test(p.user)) return "install and user are ids"
  if (!str(p.user_name) || !str(p.name) || !str(p.platform, 40)) return "user_name, name and platform are required"
  if (cert.install !== p.install || cert.user !== p.user || cert.purpose !== "direct") return "cert must be the device's direct cert"
  return { install: p.install, user: p.user, user_name: p.user_name, name: p.name, platform: p.platform, public_jwk: jwk, cert }
}

/** Requests past their expiry leave on the next write (the owner never accepts them). */
const live = (state: TrustState, now: number): TrustState => {
  const requests = Object.fromEntries(Object.entries(state.requests).filter(([, r]) => r.expires_at > now))
  return Object.keys(requests).length === Object.keys(state.requests).length ? state : { ...state, requests }
}

const ok = (state: TrustState, value: unknown, changed = true): ReduceResult<TrustState> => ({ ok: true, state, value, changed })

export const trustDomain: Domain<TrustState> = {
  initial: () => ({ devices: {}, guests: {}, requests: {}, remote: {} }),
  reduce: (prior, op, params, ctx) => {
    const state = live(prior, ctx.now)
    const pruned = state !== prior
    const p = isObj(params) ? params : {}
    switch (op) {
      case "trust.key.set": {
        const cert = parseLinkCert(p.cert)
        if (typeof cert === "string") return reject("validation.invalid", cert)
        if (!STORED_PURPOSES.has(cert.purpose)) return reject("validation.invalid", "only direct and wg certs are stored")
        const jwk = jwkOf(p.public_jwk)
        if (!jwk || !str(p.kind, 20) || !str(p.name) || !str(p.platform, 40)) return reject("validation.invalid", "device kind, name, platform and public_jwk are required")
        if (p.host !== undefined && (!str(p.host, 80) || !ID.test(p.host))) return reject("validation.invalid", "host must be a host id")
        const cur = state.devices[cert.install]
        if (!cur && Object.keys(state.devices).length >= MAX_TRUST_DEVICES) return reject("validation.invalid", `at most ${MAX_TRUST_DEVICES} devices`)
        // A replayed older cert never replaces a newer one (rotation is monotonic per purpose).
        const prev = cur?.certs[cert.purpose as "direct" | "wg"]
        if (prev && prev.issued_at > cert.issued_at) return reject("trust.cert_stale", "a newer cert is already published")
        const host = (p.host as string | undefined) ?? cur?.host
        const next: TrustDevice = {
          install: cert.install,
          kind: p.kind,
          name: p.name,
          platform: p.platform,
          public_jwk: jwk,
          ...(host ? { host } : {}),
          certs: { ...(cur?.certs ?? {}), [cert.purpose]: cert },
          updated_at: ctx.now
        }
        if (!pruned && JSON.stringify(cur) === JSON.stringify({ ...next, updated_at: cur?.updated_at })) return ok(state, { install: cert.install, purpose: cert.purpose }, false)
        return ok({ ...state, devices: { ...state.devices, [cert.install]: next } }, { install: cert.install, purpose: cert.purpose })
      }
      case "trust.install.revoked": {
        // Install revocation (install.revoke, sign_out, revoke_by_team): its keys and any acceptance it holds go.
        if (!str(p.install, 80)) return reject("validation.invalid", "install is required")
        const install = p.install
        const drop = <T extends { install: string }>(m: Readonly<Record<string, T>>) => Object.fromEntries(Object.entries(m).filter(([, v]) => v.install !== install))
        const next: TrustState = { ...state, devices: drop(state.devices), remote: drop(state.remote) }
        const changed = Object.keys(next.devices).length !== Object.keys(state.devices).length || Object.keys(next.remote).length !== Object.keys(state.remote).length
        return ok(changed ? next : state, { install }, changed || pruned)
      }
      case "trust.request.add": {
        const peer = peerOf(p)
        if (typeof peer === "string") return reject("validation.invalid", peer)
        if (!str(p.offer_id, 64) || !B64U.test(p.offer_id) || !str(p.host, 80) || !str(p.host_name) || !str(p.team, 80)) return reject("validation.invalid", "offer_id, host, host_name and team are required")
        if (!Number.isSafeInteger(p.expires_at) || (p.expires_at as number) <= ctx.now) return reject("validation.invalid", "expires_at must be in the future")
        if (state.requests[p.offer_id]) return ok(state, { offer_id: p.offer_id }, pruned)
        if (Object.keys(state.requests).length >= MAX_TRUST_REQUESTS) return reject("validation.invalid", `at most ${MAX_TRUST_REQUESTS} pending requests`)
        const request: TrustRequest = { ...peer, offer_id: p.offer_id, host: p.host, host_name: p.host_name, team: p.team, at: ctx.now, expires_at: p.expires_at as number }
        return ok({ ...state, requests: { ...state.requests, [p.offer_id]: request } }, { offer_id: p.offer_id })
      }
      case "trust.request.remove": {
        if (!str(p.offer_id, 64)) return reject("validation.invalid", "offer_id is required")
        if (!state.requests[p.offer_id]) return ok(state, { offer_id: p.offer_id }, pruned)
        const { [p.offer_id]: _gone, ...requests } = state.requests
        return ok({ ...state, requests }, { offer_id: p.offer_id })
      }
      case "trust.guest.add": {
        const peer = peerOf(p)
        if (typeof peer === "string") return reject("validation.invalid", peer)
        if (!str(p.offer_id, 64) || !str(p.host, 80) || !str(p.team, 80)) return reject("validation.invalid", "offer_id, host and team are required")
        const key = pairKey(p.host, peer.install)
        const { [p.offer_id]: _accepted, ...requests } = state.requests
        if (state.guests[key]?.offer_id === p.offer_id) return ok({ ...state, requests }, { host: p.host, install: peer.install }, pruned || state.requests[p.offer_id] !== undefined)
        if (!state.guests[key] && Object.keys(state.guests).length >= MAX_TRUST_GUESTS) return reject("validation.invalid", `at most ${MAX_TRUST_GUESTS} guest devices`)
        const guest: TrustGuest = { ...peer, offer_id: p.offer_id, host: p.host, team: p.team, accepted_at: ctx.now }
        return ok({ ...state, requests, guests: { ...state.guests, [key]: guest } }, { host: p.host, install: peer.install })
      }
      case "trust.remote.add": {
        const cert = parseLinkCert(p.cert)
        if (typeof cert === "string") return reject("validation.invalid", cert)
        const jwk = jwkOf(p.public_jwk)
        if (!jwk || !str(p.host, 80) || !str(p.team, 80) || !str(p.owner_user, 80) || !str(p.name) || !str(p.host_install, 80) || !str(p.install, 80) || !str(p.offer_id, 64)) return reject("validation.invalid", "remote host fields are required")
        if (cert.purpose !== "direct" || cert.install !== p.host_install || cert.user !== p.owner_user) return reject("validation.invalid", "cert must be the host's direct cert")
        const key = pairKey(p.host, p.install)
        if (state.remote[key]?.offer_id === p.offer_id) return ok(state, { host: p.host, install: p.install }, pruned)
        if (!state.remote[key] && Object.keys(state.remote).length >= MAX_TRUST_REMOTE) return reject("validation.invalid", `at most ${MAX_TRUST_REMOTE} remote hosts`)
        const remote: TrustRemote = { host: p.host, team: p.team, owner_user: p.owner_user, name: p.name, host_install: p.host_install, public_jwk: jwk, cert, install: p.install, offer_id: p.offer_id, accepted_at: ctx.now }
        return ok({ ...state, remote: { ...state.remote, [key]: remote } }, { host: p.host, install: p.install })
      }
      case "trust.guest.remove":
      case "trust.remote.remove": {
        if (!str(p.host, 80) || !str(p.install, 80)) return reject("validation.invalid", "host and install are required")
        const field = op === "trust.guest.remove" ? "guests" : "remote"
        const key = pairKey(p.host, p.install)
        if (!state[field][key]) return ok(state, { host: p.host, install: p.install }, pruned)
        const { [key]: _gone, ...rest } = state[field] as Record<string, unknown>
        return ok({ ...state, [field]: rest } as TrustState, { host: p.host, install: p.install })
      }
      default:
        return reject("validation.invalid", `unknown op ${op} for trust`)
    }
  },
  // Writes come only from this UserDO's pairing handlers or another UserDO's (DO RPC), as system principals.
  authorize: (_state, _op, _params, principal: Principal) =>
    principal.kind === "system" && principal.identity.startsWith("system:user") ? undefined : { code: "auth.forbidden", message: "trust changes go through the pairing ops" }
}
