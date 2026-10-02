import type { Principal } from "@cmux/ownership"
import { challengeMessagePrefix } from "@cmux/protocol"
import { verifyInstallSignature, type InstallClaims } from "./auth.ts"
import { userDomain, type UserState } from "./domains/user.ts"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

const CHALLENGE_TTL_MS = 2 * 60_000

export type RedeemResult = ({ ok: true } & InstallClaims) | { ok: false; code: "auth.forbidden" | "validation.invalid"; message: string }

/**
 * UserDO: the user's installs, devices, grants and revocation (identity spec
 * section 2). Also verifies install proof of possession for token mint; the
 * one-time challenges live outside the op protocol because they are
 * credentials, not shared entity state.
 */
export class UserDO extends OwnerDO<UserState> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env, userDomain, "user")
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS auth_challenges (nonce TEXT PRIMARY KEY, install TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  }

  protected read(state: UserState, op: string, _params: unknown, principal: Principal): ReadResult {
    if (state.user && principal.user !== state.user.id) return { ok: false, code: "auth.forbidden", message: "not this user" }
    if (op !== "install.list") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { user: state.user, installs: Object.values(state.installs), grants: Object.values(state.grants) }, revision: "" }
  }

  protected maySubscribe(state: UserState, principal: Principal): boolean {
    return !state.user || state.user.id === principal.user
  }

  async challenge(entity: string, install: string): Promise<{ ok: true; nonce: string; expires_at: number } | { ok: false; message: string }> {
    const engine = this.bind(entity)
    const inst = engine.currentState.installs[install]
    if (!inst || inst.revoked_at !== null) return { ok: false, message: "install unknown or revoked" }
    const now = Date.now()
    const nonce = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "")
    const sql = this.ctx.storage.sql
    sql.exec(`DELETE FROM auth_challenges WHERE expires_at < ?`, now)
    sql.exec(`INSERT INTO auth_challenges (nonce, install, expires_at) VALUES (?, ?, ?)`, nonce, install, now + CHALLENGE_TTL_MS)
    return { ok: true, nonce, expires_at: now + CHALLENGE_TTL_MS }
  }

  /** One-time challenge + ES256 signature by the install key + revocation check. */
  async redeem(entity: string, install: string, nonce: string, signature: string): Promise<RedeemResult> {
    const engine = this.bind(entity)
    const sql = this.ctx.storage.sql
    const row = sql.exec<{ install: string; expires_at: number }>(`SELECT install, expires_at FROM auth_challenges WHERE nonce = ?`, nonce).toArray()[0]
    // Consume first: a nonce is single use even when the signature fails.
    sql.exec(`DELETE FROM auth_challenges WHERE nonce = ?`, nonce)
    if (!row || row.install !== install || row.expires_at < Date.now()) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
    const state = engine.currentState
    const inst = state.installs[install]
    if (!inst || inst.revoked_at !== null || !state.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    const grant = state.grants[inst.grant]
    if (!grant || grant.revoked_at !== null) return { ok: false, code: "auth.forbidden", message: "grant revoked" }
    const ok = await verifyInstallSignature(inst.public_jwk, `${challengeMessagePrefix(this.env.ENVIRONMENT, install)}${nonce}`, signature)
    if (!ok) return { ok: false, code: "auth.forbidden", message: "bad signature" }
    return { ok: true, user: state.user.id, team: state.user.personal_team, install, grant: grant.id }
  }
}
