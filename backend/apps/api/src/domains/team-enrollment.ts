import { createHash } from "node:crypto"
import type { Reject, ReduceContext } from "@cmux/ownership"
import {
  DeviceEnroll,
  DeviceRelease,
  deviceScopedPolicyKeys,
  EnrollmentTokenCreate,
  EnrollmentTokenRevoke,
  type EnrollmentToken,
  type ManagedDevice
} from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { currentPolicy, type PolicyState } from "./team-policy.ts"

export type Token = typeof EnrollmentToken.Type
export type Device = typeof ManagedDevice.Type

/**
 * Enrollment tokens with `sha256(token_hash)`. Exposure model: op params (so
 * `token_hash`) reach every member in events, and state reaches them in
 * snapshots. Only members subscribe, and a member can already enroll their
 * own installs by explicit acceptance, so a member who learns a hash gains
 * nothing. Non-members never see either. If a later phase lets a token admit
 * non-members, the token must move out of op params (sealed side table, as
 * ConnectionDO does for credentials).
 */
export interface StoredToken extends Token {
  readonly token_hash: string
}

export const storedHash = (tokenHash: string) => createHash("sha256").update(tokenHash).digest("base64url")

export interface EnrollmentState extends PolicyState {
  readonly enrollment_tokens?: Readonly<Record<string, StoredToken>>
  readonly managed_devices?: Readonly<Record<string, Device>>
}

export const MAX_TOKENS = 100

type Result<S> = { ok: true; state: S; value: unknown; changed?: boolean; audit?: { summary: string; detail: unknown } } | ({ ok: false } & Reject)

export const publicToken = ({ token_hash: _hash, ...t }: StoredToken): Token => t

export const reduceTokenCreate = <S extends EnrollmentState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof EnrollmentTokenCreate.params.Type>(EnrollmentTokenCreate, params)
  if (!d.ok) return d
  const tokens = state.enrollment_tokens ?? {}
  const stored = storedHash(d.value.token_hash)
  if (Object.values(tokens).some((t) => t.token_hash === stored)) return reject("policy.invalid", "this token already exists")
  if (Object.values(tokens).filter((t) => t.revoked_at === null).length >= MAX_TOKENS) return reject("policy.invalid", `at most ${MAX_TOKENS} active tokens`)
  if (d.value.expires_at !== undefined && d.value.expires_at <= ctx.now) return reject("policy.invalid", "expires_at is in the past")
  const id = ctx.newId("enr")
  const token: StoredToken = {
    id,
    label: d.value.label,
    token_hash: stored,
    allowed_domains: d.value.allowed_domains ? [...new Set(d.value.allowed_domains)] : null,
    expires_at: d.value.expires_at ?? null,
    created_by: ctx.principal.user ?? ctx.principal.identity,
    created_at: ctx.now,
    revoked_at: null,
    uses: 0
  }
  return {
    ok: true,
    state: { ...state, enrollment_tokens: { ...tokens, [id]: token } },
    value: publicToken(token),
    audit: { summary: `enrollment token ${id} created`, detail: publicToken(token) }
  }
}

export const reduceTokenRevoke = <S extends EnrollmentState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof EnrollmentTokenRevoke.params.Type>(EnrollmentTokenRevoke, params)
  if (!d.ok) return d
  const t = state.enrollment_tokens?.[d.value.token]
  if (!t) return reject("selector.not_found", "enrollment token not found")
  if (t.revoked_at !== null) return { ok: true, state, value: publicToken(t), changed: false }
  const next = { ...t, revoked_at: ctx.now }
  return {
    ok: true,
    state: { ...state, enrollment_tokens: { ...state.enrollment_tokens, [t.id]: next } },
    value: publicToken(next),
    audit: { summary: `enrollment token ${t.id} revoked`, detail: { token: t.id } }
  }
}

const emailDomain = (email: string | null | undefined) => (email && email.includes("@") ? email.split("@").pop()!.toLowerCase() : null)

/**
 * Enrolls the calling install. The caller must already be a member: a token
 * alone never grants membership (anyone can read a managed preference file).
 * Joining a team by verified domain comes with DomainDO (phase 2c).
 */
export const reduceDeviceEnroll = <S extends EnrollmentState>(state: S, params: unknown, ctx: ReduceContext, email: string | null | undefined): Result<S> => {
  const d = decodeParams<typeof DeviceEnroll.params.Type>(DeviceEnroll, params)
  if (!d.ok) return d
  const p = ctx.principal
  if (!p.install || !p.user) return reject("auth.forbidden", "team.device.enroll needs an install token")
  let tokens = state.enrollment_tokens ?? {}
  let via: Device["via"] = "accept"
  let tokenId: string | null = null
  if (d.value.token_hash !== undefined) {
    const stored = storedHash(d.value.token_hash)
    const t = Object.values(tokens).find((x) => x.token_hash === stored)
    // One message for unknown, revoked and expired: no token oracle.
    if (!t || t.revoked_at !== null || (t.expires_at !== null && t.expires_at <= ctx.now)) return reject("policy.invalid", "enrollment token is not valid")
    if (t.allowed_domains && !t.allowed_domains.includes(emailDomain(email) ?? "")) return reject("policy.invalid", "this account's email domain may not use this enrollment token")
    via = "token"
    tokenId = t.id
  }
  const existing = state.managed_devices?.[p.install]
  if (existing && existing.user === p.user && existing.via === via && existing.token === tokenId) return { ok: true, state, value: existing, changed: false }
  if (tokenId) tokens = { ...tokens, [tokenId]: { ...tokens[tokenId]!, uses: tokens[tokenId]!.uses + 1 } }
  const device: Device = { install: p.install, user: p.user, via, token: tokenId, at: ctx.now }
  return {
    ok: true,
    state: { ...state, enrollment_tokens: tokens, managed_devices: { ...state.managed_devices, [p.install]: device } },
    value: device,
    audit: { summary: `install ${p.install} enrolled (${via})`, detail: device }
  }
}

export const reduceDeviceRelease = <S extends EnrollmentState>(state: S, params: unknown, ctx: ReduceContext, isAdmin: boolean): Result<S> => {
  const d = decodeParams<typeof DeviceRelease.params.Type>(DeviceRelease, params)
  if (!d.ok) return d
  const device = state.managed_devices?.[d.value.install]
  if (!device) return reject("selector.not_found", "install is not managed by this team")
  if (device.user !== ctx.principal.user && !isAdmin) return reject("auth.forbidden", "only the install's user or a team admin may release it")
  const { [d.value.install]: _gone, ...rest } = state.managed_devices ?? {}
  return {
    ok: true,
    state: { ...state, managed_devices: rest },
    value: { install: d.value.install },
    audit: { summary: `install ${d.value.install} released`, detail: { install: d.value.install } }
  }
}

/** The device-scoped layer for a managed install (team.device.policy). */
export const devicePolicyFor = (state: EnrollmentState, install: string | undefined) => {
  const policy = currentPolicy(state)
  const managed = Boolean(install && state.managed_devices?.[install])
  const defaults: Record<string, unknown> = {}
  const enforced: Record<string, unknown> = {}
  if (managed) {
    for (const [key, v] of Object.entries(policy.values)) {
      if (!v || !deviceScopedPolicyKeys.has(key as never)) continue
      ;(v.mode === "enforced" ? enforced : defaults)[key] = v.value
    }
  }
  return { managed, version: policy.version, defaults, enforced }
}
