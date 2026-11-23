import type { OwnerFrame, RejectFrame } from "@cmux/ownership"
import type { TeamState } from "./domains/team.ts"
import type { StackServer } from "./stack-server.ts"

/**
 * Sign-in hand-off to another device of the same person (`cmux auth handoff mint|redeem`).
 *
 * The person's signed-in cmux app mints a one-time code with its own human Stack session
 * (POST /v1/auth/handoffs); the code travels only over ssh stdin to the other device, whose app
 * redeems it (POST /v1/auth/handoffs/redeem) and gets a NEW Stack session for the same user
 * (Stack's server `POST /auth/sessions`, as SSO sign-in opens one). Nothing secret is copied
 * from the minting device, and no session is stored here: the record keeps only the code's hash,
 * so nothing needs sealing (the SSO redeem seals because its session exists before the redeem).
 *
 * Run by the person's personal TeamDO (the code names it, as an SSO redeem code names its team):
 * - a code lives HANDOFF_TTL_MS (2 min) and is spent once, before Stack is asked, so a replay or a
 *   concurrent second redeem never gets a session;
 * - at most MINT_LIMIT mints per MINT_WINDOW_MS (5 per 10 min) per person;
 * - a redeem that names the user the target app is signed in as (`expected_user`, the Stack id) and
 *   finds another user is refused without spending the code;
 * - every mint, redeem and refusal is on the team's audit chain (auth.handoff.*), never the code.
 */
export const HANDOFF_TTL_MS = 120_000
export const MINT_LIMIT = 5
export const MINT_WINDOW_MS = 10 * 60_000

/** `cmh_<personal team>.<43 base64url>`: the team routes the redeem; the random part is the secret. */
export const HANDOFF_CODE = /^cmh_(team_[a-z0-9]{20})\.[A-Za-z0-9_-]{43}$/
/** A device label as the client names itself: printable, short. */
export const DEVICE_LABEL = /^[^\u0000-\u001f\u007f]{1,64}$/

export const teamOfHandoffCode = (code: string): string | undefined => HANDOFF_CODE.exec(code)?.[1]

const enc = new TextEncoder()
const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const random = (n = 32) => b64u(crypto.getRandomValues(new Uint8Array(n)))
const sha256 = async (s: string) => b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s))))

export interface HandoffDeps {
  readonly state: TeamState
  readonly team: string
  readonly sql: SqlStorage
  readonly stack: StackServer | undefined
  readonly now: number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

export type HandoffError = { readonly ok: false; readonly code: HandoffErrorCode; readonly message: string }
export type HandoffErrorCode =
  | "auth_handoff.no_account"
  | "auth_handoff.rate_limited"
  | "auth_handoff.invalid"
  | "auth_handoff.other_user"
  | "auth_handoff.unavailable"

export interface Minter {
  /** The platform user id (`user_…`). */
  readonly user: string
  readonly stack_user: string
  readonly email: string | null
  /** The minting session's Stack refresh_token_id, for the audit. */
  readonly session: string | undefined
  readonly device: string | undefined
}

export type Minted = { readonly ok: true; readonly code: string; readonly expires_at: number; readonly user: string; readonly email: string | null; readonly device: string | null }

export interface RedeemAsk {
  readonly code: string
  readonly device: string | undefined
  /** The Stack user id the redeeming app is signed in as now, if any. */
  readonly expected_user: string | undefined
}

/**
 * A redeem's answer. `already_signed_in`: the device is already signed in as this user (its
 * `expected_user`), so the code is spent and no new session is made (no tokens).
 */
export type Redeemed = {
  readonly ok: true
  readonly already_signed_in: boolean
  readonly access_token?: string
  readonly refresh_token?: string
  readonly user: string
  readonly stack_user: string
  readonly email: string | null
  readonly device: string | null
  readonly minted_device: string | null
}

const INVALID: HandoffError = { ok: false, code: "auth_handoff.invalid", message: "the hand-off code expired, was used, or is not a code" }

export const ensureHandoffTables = (sql: SqlStorage) => {
  sql.exec(
    `CREATE TABLE IF NOT EXISTS auth_handoffs1 (code_hash TEXT PRIMARY KEY, user TEXT NOT NULL, stack_user TEXT NOT NULL, email TEXT, minted_device TEXT, minted_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, spent_at INTEGER, redeemed_device TEXT)`
  )
}

/** Audit, best effort for the caller: a refused audit is logged, never surfaced (the answer stands). */
const audit = (deps: HandoffDeps, op: string, params: Record<string, unknown>, key: string) => {
  const clean = Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined && v !== null))
  try {
    const r = deps.submitSystem(op, clean, key)
    if (r.frames.some((f): f is RejectFrame => f.t === "reject")) console.error(JSON.stringify({ msg: "auth handoff audit refused", op }))
  } catch (e) {
    console.error(JSON.stringify({ msg: "auth handoff audit failed", op, error: String(e) }))
  }
}

const refuse = (deps: HandoffDeps, stage: "mint" | "redeem", reason: string, extra: Record<string, unknown> = {}) =>
  audit(deps, "auth.handoff.refused", { stage, reason, ...extra }, `auth-handoff-refused:${stage}:${reason}:${deps.now}:${random(9)}`)

/** POST /v1/auth/handoffs, after the Worker checked a human session and the SSO binding. */
export const mintHandoff = async (deps: HandoffDeps, minter: Minter): Promise<Minted | HandoffError> => {
  const team = deps.state.team
  if (!team || team.id !== deps.team || team.kind !== "personal") {
    return { ok: false, code: "auth_handoff.no_account", message: "this account has no cmux profile yet: open cmux and sign in once" }
  }
  ensureHandoffTables(deps.sql)
  // Rows older than the rate window go; a younger row (spent or not) still counts against the limit.
  deps.sql.exec(`DELETE FROM auth_handoffs1 WHERE minted_at <= ?`, deps.now - MINT_WINDOW_MS)
  const recent = deps.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM auth_handoffs1 WHERE minted_at > ?`, deps.now - MINT_WINDOW_MS).one().n
  if (recent >= MINT_LIMIT) {
    refuse(deps, "mint", "rate_limited", { device: minter.device, session: minter.session })
    return { ok: false, code: "auth_handoff.rate_limited", message: `at most ${MINT_LIMIT} hand-off codes per ${MINT_WINDOW_MS / 60_000} minutes; try again later` }
  }
  const code = `cmh_${deps.team}.${random()}`
  const hash = await sha256(code)
  const expiresAt = deps.now + HANDOFF_TTL_MS
  deps.sql.exec(
    `INSERT INTO auth_handoffs1 (code_hash, user, stack_user, email, minted_device, minted_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    hash, minter.user, minter.stack_user, minter.email, minter.device ?? null, deps.now, expiresAt
  )
  audit(deps, "auth.handoff.minted", { handoff: hash.slice(0, 12), device: minter.device, session: minter.session, expires_at: expiresAt }, `auth-handoff-minted:${hash}`)
  return { ok: true, code, expires_at: expiresAt, user: minter.user, email: minter.email, device: minter.device ?? null }
}

/** POST /v1/auth/handoffs/redeem: a new Stack session for the minting user, once. */
export const redeemHandoff = async (deps: HandoffDeps, ask: RedeemAsk): Promise<Redeemed | HandoffError> => {
  if (teamOfHandoffCode(ask.code) !== deps.team) return INVALID
  ensureHandoffTables(deps.sql)
  const hash = await sha256(ask.code)
  const handoff = hash.slice(0, 12)
  const row = deps.sql
    .exec<{ user: string; stack_user: string; email: string | null; minted_device: string | null; expires_at: number; spent_at: number | null }>(
      `SELECT user, stack_user, email, minted_device, expires_at, spent_at FROM auth_handoffs1 WHERE code_hash = ?`,
      hash
    )
    .toArray()[0]
  if (!row || row.spent_at !== null || row.expires_at <= deps.now) {
    refuse(deps, "redeem", !row ? "unknown" : row.spent_at !== null ? "spent" : "expired", { handoff, device: ask.device })
    return INVALID
  }
  // The target app is signed in as someone else: refused, and the code stays usable.
  if (ask.expected_user !== undefined && ask.expected_user !== row.stack_user) {
    refuse(deps, "redeem", "other_user", { handoff, device: ask.device })
    return { ok: false, code: "auth_handoff.other_user", message: "this device is signed in to cmux as another account; sign out there first" }
  }
  // Spent before Stack is asked: the DO interleaves at each await, so a concurrent redeem finds it spent.
  deps.sql.exec(`UPDATE auth_handoffs1 SET spent_at = ?, redeemed_device = ? WHERE code_hash = ? AND spent_at IS NULL`, deps.now, ask.device ?? null, hash)
  const who = { user: row.user, stack_user: row.stack_user, email: row.email, device: ask.device ?? null, minted_device: row.minted_device }
  // Already signed in as this very user: nothing to hand over, and no extra session left alive.
  if (ask.expected_user === row.stack_user) {
    audit(deps, "auth.handoff.redeemed", { handoff, device: ask.device, minted_device: row.minted_device, reason: "already_signed_in" }, `auth-handoff-redeemed:${hash}`)
    return { ok: true, already_signed_in: true, ...who }
  }
  if (!deps.stack) {
    refuse(deps, "redeem", "stack_unconfigured", { handoff, device: ask.device })
    return { ok: false, code: "auth_handoff.unavailable", message: "sign-in hand-off is not configured on this deployment" }
  }
  let session: { access_token: string; refresh_token: string }
  try {
    session = await deps.stack.createSession(row.stack_user, undefined)
  } catch (e) {
    console.error(JSON.stringify({ msg: "auth handoff session failed at Stack", error: String(e) }))
    refuse(deps, "redeem", "stack_failed", { handoff, device: ask.device })
    return { ok: false, code: "auth_handoff.unavailable", message: "the sign-in service did not answer; mint a new code and try again" }
  }
  audit(deps, "auth.handoff.redeemed", { handoff, device: ask.device, minted_device: row.minted_device }, `auth-handoff-redeemed:${hash}`)
  return { ok: true, already_signed_in: false, access_token: session.access_token, refresh_token: session.refresh_token, ...who }
}
