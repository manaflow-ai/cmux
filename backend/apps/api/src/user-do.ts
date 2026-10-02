import type { OwnerFrame, Principal } from "@cmux/ownership"
import { challengeMessagePrefix } from "@cmux/protocol"
import { verifyInstallSignature, type InstallClaims } from "./auth.ts"
import { resolveAppRelease } from "./app-do.ts"
import { appsView } from "./domains/app-installs.ts"
import { installActive, userDomain, type UserState } from "./domains/user.ts"
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
    if (op === "app.list") return { ok: true, value: appsView(state.apps, Date.now(), "user"), revision: "" }
    if (op !== "install.list") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    return { ok: true, value: { user: state.user, installs: Object.values(state.installs), grants: Object.values(state.grants) }, revision: "" }
  }

  /** Installs, updates and approvals decide against the release AppDO resolves now. */
  protected override resolve(_entity: string, state: UserState, op: string, params: unknown): Promise<unknown> {
    return resolveAppRelease(this.env, "user", state.apps, op, params)
  }

  protected maySubscribe(state: UserState, principal: Principal): boolean {
    return (!state.user || state.user.id === principal.user) && installActive(state, principal)
  }

  /** A revoked install loses its open sockets at once, not at token expiry. */
  protected override afterOp(_principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>) {
    if (op !== "install.revoke") return
    const result = frames.find((f) => f.t === "result")
    const revoked = result && result.t === "result" ? (result.value as { id?: string }).id : undefined
    if (revoked) this.closeSockets((p) => p.install === revoked, "install revoked")
  }

  /** Bound user state, or undefined for an id this object never served (no storage is created). */
  private existing() {
    const row = this.ctx.storage.sql.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`).toArray()[0]
    return row ? this.bind(row.entity) : undefined
  }

  /** For other owners (TeamDO): is this install active, and what does its grant allow? */
  async installGrant(entity: string, install: string, grant: string): Promise<{ ok: true; op_classes: ReadonlyArray<string> } | { ok: false }> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false }
    const state = engine.currentState
    const inst = state.installs[install]
    const g = state.grants[grant]
    if (!inst || inst.revoked_at !== null || inst.grant !== grant || !g || g.revoked_at !== null || (g.expires_at !== null && g.expires_at <= Date.now())) return { ok: false }
    return { ok: true, op_classes: g.op_classes }
  }

  async challenge(entity: string, install: string): Promise<{ ok: true; nonce: string; expires_at: number } | { ok: false; message: string }> {
    const engine = this.existing()
    // One answer for every refusal, so the endpoint does not reveal which users or installs exist.
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, message: "challenge refused" }
    const inst = engine.currentState.installs[install]
    if (!inst || inst.revoked_at !== null) return { ok: false, message: "challenge refused" }
    const now = Date.now()
    const nonce = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "")
    const sql = this.ctx.storage.sql
    sql.exec(`DELETE FROM auth_challenges WHERE expires_at < ?`, now)
    sql.exec(`INSERT INTO auth_challenges (nonce, install, expires_at) VALUES (?, ?, ?)`, nonce, install, now + CHALLENGE_TTL_MS)
    return { ok: true, nonce, expires_at: now + CHALLENGE_TTL_MS }
  }

  /** One-time challenge + ES256 signature by the install key + revocation check. */
  async redeem(entity: string, install: string, nonce: string, signature: string): Promise<RedeemResult> {
    const engine = this.existing()
    if (!engine || engine.stream !== `user:${entity}`) return { ok: false, code: "auth.forbidden", message: "challenge unknown, used or expired" }
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
    // Re-read after the await: a revoke may have committed during the verify.
    const now = engine.currentState
    const stillActive = now.installs[install]?.revoked_at === null && now.grants[grant.id]?.revoked_at === null
    if (!stillActive || !now.user) return { ok: false, code: "auth.forbidden", message: "install unknown or revoked" }
    return { ok: true, user: now.user.id, team: now.user.personal_team, install, grant: grant.id }
  }
}
