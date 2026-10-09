import { challengeMessagePrefix } from "@cmux/protocol"
import { emailDomainOf, verifyInstallSignature } from "./auth.ts"
import { isMachineInstallKind } from "./machine-installs.ts"
import { chiefActive, type UserState } from "./domains/user.ts"
import type { Env } from "./env.ts"
import type { RedeemResult } from "./user-do.ts"

/**
 * Install token challenges (identity spec section 2), moved out of user-do.ts unchanged: a
 * one-time nonce per install in `auth_challenges`, redeemed with an ES256 signature by the install
 * key and a revocation check before and after the signature verify.
 */

/** A fresh nonce for an active install; one answer for every refusal (no oracle for users or installs). */
export const issueChallenge = (sql: SqlStorage, state: UserState | undefined, install: string, ttlMs: number): { ok: true; nonce: string; expires_at: number } | { ok: false; message: string } => {
  const inst = state?.installs[install]
  if (!inst || inst.revoked_at !== null) return { ok: false, message: "challenge refused" }
  const now = Date.now()
  const nonce = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "")
  sql.exec(`DELETE FROM auth_challenges WHERE expires_at < ?`, now)
  sql.exec(`INSERT INTO auth_challenges (nonce, install, expires_at) VALUES (?, ?, ?)`, nonce, install, now + ttlMs)
  return { ok: true, nonce, expires_at: now + ttlMs }
}

/** `current` reads the bound state again after the await: a revoke may commit during the verify. */
export const redeemChallenge = async (env: Env, sql: SqlStorage, current: () => UserState, install: string, nonce: string, signature: string, agent?: string): Promise<RedeemResult> => {
  const row = sql.exec<{ install: string; expires_at: number }>(`SELECT install, expires_at FROM auth_challenges WHERE nonce = ?`, nonce).toArray()[0]
  // Consume first: a nonce is single use even when the signature fails.
  sql.exec(`DELETE FROM auth_challenges WHERE nonce = ?`, nonce)
  if (!row || row.install !== install || row.expires_at < Date.now()) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
  const state = current()
  const inst = state.installs[install]
  if (!inst || inst.revoked_at !== null || !state.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
  const grant = state.grants[inst.grant]
  if (!grant || grant.revoked_at !== null) return { ok: false, code: "auth.forbidden", message: "grant revoked" }
  const ok = await verifyInstallSignature(inst.public_jwk, `${challengeMessagePrefix(env.ENVIRONMENT, install)}${nonce}`, signature)
  if (!ok) return { ok: false, code: "auth.forbidden", message: "bad signature" }
  // Re-read after the await: a revoke may have committed during the verify.
  const now = current()
  const stillActive = now.installs[install]?.revoked_at === null && now.grants[grant.id]?.revoked_at === null
  if (!stillActive || !now.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
  // A chief token only for an unarchived chief of this user.
  if (agent !== undefined && (!chiefActive(now, agent) || isMachineInstallKind(inst.kind))) return { ok: false, code: "auth.forbidden", message: "agent unknown or archived" }
  const emailDomain = emailDomainOf(now.user.email)
  return { ok: true, user: now.user.id, team: isMachineInstallKind(inst.kind) && inst.bound_team ? inst.bound_team : now.user.personal_team, install, grant: grant.id, ...(inst.sso_team ? { sso_team: inst.sso_team } : {}), ...(emailDomain ? { email_domain: emailDomain } : {}), ...(agent ? { agent } : {}), ...(inst.kind === "vm" ? { vm: true as const } : {}), ...(inst.kind === "team-vm" ? { team_vm: true as const } : {}) }
}
