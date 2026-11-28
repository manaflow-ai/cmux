import { createHash } from "node:crypto"
import type { Reject, ReduceContext } from "@cmux/ownership"
import {
  DeviceEnroll,
  DeviceRelease,
  deviceScopedPolicyKeys,
  EnrollmentTokenCreate,
  EnrollmentTokenRevoke,
  DeviceReportStatus,
  type DeviceStatus,
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

export type Status = typeof DeviceStatus.Type

export interface EnrollmentState extends PolicyState {
  readonly enrollment_tokens?: Readonly<Record<string, StoredToken>>
  readonly managed_devices?: Readonly<Record<string, Device>>
  /** Latest status report per install (team.device.report_status). */
  readonly device_status?: Readonly<Record<string, Status>>
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
  // Before any lookup, so an agent cannot learn whether an install is managed.
  if (ctx.principal.kind === "agent" || ctx.principal.agent) return reject("auth.forbidden", "agents cannot release devices")
  const d = decodeParams<typeof DeviceRelease.params.Type>(DeviceRelease, params)
  if (!d.ok) return d
  const device = state.managed_devices?.[d.value.install]
  if (!device) return reject("selector.not_found", "install is not managed by this team")
  // An MDM-enrolled install belongs to the admin's enrollment: only admins release it (decision a).
  if (device.via === "token" && !isAdmin) return reject("auth.forbidden", "only a team admin may release an install enrolled by an MDM token")
  if (device.user !== ctx.principal.user && !isAdmin) return reject("auth.forbidden", "only the install's user or a team admin may release it")
  const { [d.value.install]: _gone, ...rest } = state.managed_devices ?? {}
  const { [d.value.install]: _status, ...statusRest } = state.device_status ?? {}
  return {
    ok: true,
    state: { ...state, managed_devices: rest, device_status: statusRest },
    value: { install: d.value.install },
    audit: { summary: `install ${d.value.install} released`, detail: { install: d.value.install } }
  }
}

/**
 * What `team.device.policy` returns for a managed install: cmux.json settings
 * from `device.settings` split by their own mode (the app's team layer), and
 * the device-scoped feature keys as policy values (enforced by their owners on
 * the device: MCP server, CUA host, telemetry, updater).
 */
export const devicePolicyFor = (state: EnrollmentState, install: string | undefined) => {
  const policy = currentPolicy(state)
  const managed = Boolean(install && state.managed_devices?.[install])
  const defaults: Record<string, unknown> = {}
  const enforced: Record<string, unknown> = {}
  const features: Record<string, unknown> = {}
  if (managed) {
    for (const [key, entry] of Object.entries(policy.values["device.settings"]?.value ?? {})) {
      ;(entry.mode === "enforced" ? enforced : defaults)[key] = entry.value
    }
    for (const [key, v] of Object.entries(policy.values)) {
      if (v && deviceScopedPolicyKeys.has(key as never)) features[key] = v
    }
  }
  return { managed, version: policy.version, defaults, enforced, features }
}

/** The install's latest report replaces the previous one; an identical report changes nothing. */
export const reduceReportStatus = <S extends EnrollmentState>(state: S, params: unknown, ctx: ReduceContext): Result<S> => {
  const d = decodeParams<typeof DeviceReportStatus.params.Type>(DeviceReportStatus, params)
  if (!d.ok) return d
  const p = ctx.principal
  if (!p.install || !p.user) return reject("auth.forbidden", "team.device.report_status needs an install token")
  // Only managed installs report: compliance reads nothing else, and TeamDO state is one row.
  if (state.managed_devices?.[p.install]?.user !== p.user) return reject("selector.not_found", "this install is not managed by this team")
  const prev = state.device_status?.[p.install]
  const next: Status = {
    install: p.install,
    user: p.user,
    policy_version: d.value.policy_version,
    app_version: d.value.app_version,
    mdm_keys: [...new Set(d.value.mdm_keys)].sort(),
    conflicts: [...new Set(d.value.conflicts)].sort(),
    reported_at: ctx.now
  }
  if (prev && JSON.stringify({ ...prev, reported_at: 0 }) === JSON.stringify({ ...next, reported_at: 0 })) return { ok: true, state, value: prev, changed: false }
  return { ok: true, state: { ...state, device_status: { ...state.device_status, [p.install]: next } }, value: next }
}

/** Compliance per managed device: applied the current version and no MDM conflicts. */
export const complianceFor = (state: EnrollmentState) => {
  const version = currentPolicy(state).version
  return {
    policy_version: version,
    devices: Object.values(state.managed_devices ?? {})
      .sort((a, b) => (a.install < b.install ? -1 : 1))
      .map((device) => {
        const status = state.device_status?.[device.install] ?? null
        const reasons: Array<string> = []
        if (!status) reasons.push("no status report")
        else {
          if (status.policy_version !== version) reasons.push(`applied policy v${status.policy_version}, current v${version}`)
          if (status.conflicts.length > 0) reasons.push(`MDM overrides team policy: ${status.conflicts.join(", ")}`)
        }
        return { device, status, compliant: reasons.length === 0, reasons }
      })
  }
}
