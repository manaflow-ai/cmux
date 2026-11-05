import type { Env } from "./env.ts"

/**
 * A person's invites, on the PairingDO instance `invite-user:<user>` (pair-invite-routes.ts).
 *
 * - Idempotency: each `server.pair.invite` key (its SHA-256) maps to the invite it minted, so a
 *   replay answers the same invite and voids nothing. A key is recorded (pending) before its
 *   invite is minted and committed after, so concurrent or retried requests with one key mint
 *   one invite.
 * - One live invite: committing a key makes its invite the live one and queues the previous live
 *   invite for a void. The void is retried on this object's alarm until the invite's object
 *   answers, and a key left pending by a request that died is resolved on the alarm too (its
 *   invite adopted when it was minted, forgotten when not), so a failure between the Durable
 *   Object calls never leaves two live invites.
 */

/** How long a pending key or a failed void waits before the alarm resolves it. */
export const OWNER_RECHECK_MS = 30_000
/** How long a key replays its invite. */
export const OWNER_KEY_RETENTION_MS = 60 * 60_000

type MintRow = { key: string; invite: string; team: string; created_at: number; expires_at: number | null }

export type OwnerBegin = { readonly state: "fresh" } | { readonly state: "replay"; readonly invite: string; readonly expires_at: number | null } | { readonly state: "conflict" }

export const ownerSchema = (sql: SqlStorage): void => {
  sql.exec(`CREATE TABLE IF NOT EXISTS pair_invite_mint (key TEXT PRIMARY KEY, invite TEXT NOT NULL, team TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS pair_invite_live (id INTEGER PRIMARY KEY CHECK (id = 1), invite TEXT NOT NULL, created_at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS pair_invite_void (invite TEXT PRIMARY KEY)`)
}

export class InviteOwner {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env
  ) {}

  private get sql() {
    return this.ctx.storage.sql
  }

  /** Whether this object holds a person's invites (so its alarm is the owner's). */
  holdsOwnerState(): boolean {
    const n = (t: string) => this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM ${t}`).toArray()[0]!.n
    return n("pair_invite_mint") + n("pair_invite_live") + n("pair_invite_void") > 0
  }

  private async wakeAt(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > at) await this.ctx.storage.setAlarm(at)
  }

  /** Records `key` for `invite` (pending), or answers what the key already holds. */
  async begin(key: string, invite: string, team: string, now: number): Promise<OwnerBegin> {
    const r = this.sql.exec<MintRow>(`SELECT * FROM pair_invite_mint WHERE key = ?`, key).toArray()[0]
    if (r) return r.team === team ? { state: "replay", invite: r.invite, expires_at: r.expires_at } : { state: "conflict" }
    this.sql.exec(`INSERT INTO pair_invite_mint (key, invite, team, created_at, expires_at) VALUES (?, ?, ?, ?, NULL)`, key, invite, team, now)
    await this.wakeAt(now + OWNER_RECHECK_MS)
    return { state: "fresh" }
  }

  /** The pending key's invite was never minted (a code collision): forget the key. */
  async forget(key: string, invite: string): Promise<void> {
    this.sql.exec(`DELETE FROM pair_invite_mint WHERE key = ? AND invite = ? AND expires_at IS NULL`, key, invite)
  }

  /**
   * The key's invite is minted: record its expiry, make it the live invite unless a newer key's
   * already is (then it is voided itself), and void the one it replaces. `skipVoid` only queues
   * the void (tests: a void that never reached its object).
   */
  async commit(key: string, invite: string, expiresAt: number, now: number, opts: { skipVoid?: boolean } = {}): Promise<{ ok: boolean }> {
    const r = this.sql.exec<MintRow>(`SELECT * FROM pair_invite_mint WHERE key = ?`, key).toArray()[0]
    if (!r || r.invite !== invite) return { ok: false }
    if (r.expires_at === null) this.sql.exec(`UPDATE pair_invite_mint SET expires_at = ? WHERE key = ?`, expiresAt, key)
    const live = this.sql.exec<{ invite: string; created_at: number }>(`SELECT invite, created_at FROM pair_invite_live WHERE id = 1`).toArray()[0]
    if (!live || (live.invite !== invite && live.created_at <= r.created_at)) {
      this.sql.exec(`INSERT OR REPLACE INTO pair_invite_live (id, invite, created_at) VALUES (1, ?, ?)`, invite, r.created_at)
      if (live) this.sql.exec(`INSERT OR IGNORE INTO pair_invite_void (invite) VALUES (?)`, live.invite)
    } else if (live.invite !== invite) {
      // A newer key's invite is live already: this one is replaced on arrival.
      this.sql.exec(`INSERT OR IGNORE INTO pair_invite_void (invite) VALUES (?)`, invite)
    }
    await this.wakeAt(now + OWNER_KEY_RETENTION_MS)
    if (opts.skipVoid) await this.wakeAt(now + OWNER_RECHECK_MS)
    else await this.drainVoids(now)
    return { ok: true }
  }

  private inviteStub(invite: string) {
    return this.env.PAIRING_DO.get(this.env.PAIRING_DO.idFromName(`invite:${invite}`))
  }

  /** Voids every queued invite (and aborts a box it bound); a failure stays queued for the alarm. */
  private async drainVoids(now: number): Promise<void> {
    const queued = this.sql.exec<{ invite: string }>(`SELECT invite FROM pair_invite_void`).toArray()
    for (const { invite } of queued) {
      try {
        const voided = await this.inviteStub(invite).inviteVoid(invite, "replaced", now)
        if (voided.code) await this.env.PAIRING_DO.get(this.env.PAIRING_DO.idFromName(voided.code)).inviteAbort(voided.code, invite, now)
        this.sql.exec(`DELETE FROM pair_invite_void WHERE invite = ?`, invite)
      } catch {
        await this.wakeAt(now + OWNER_RECHECK_MS)
      }
    }
  }

  /** The owner's alarm: resolve keys left pending, retry voids, forget keys past retention. */
  async alarm(now: number): Promise<void> {
    const pendingRows = this.sql.exec<MintRow>(`SELECT * FROM pair_invite_mint WHERE expires_at IS NULL`).toArray()
    for (const r of pendingRows) {
      try {
        // Minted: adopt it (a repeat of the request's own commit is a no-op). Not minted: forget it
        // only once a live request would have minted it, so a request in flight is never undone.
        const minted = await this.inviteStub(r.invite).inviteMinted(r.invite)
        if (minted) await this.commit(r.key, r.invite, minted.expires_at, now, { skipVoid: true })
        else if (r.created_at <= now - OWNER_RECHECK_MS) await this.forget(r.key, r.invite)
      } catch {
        await this.wakeAt(now + OWNER_RECHECK_MS)
      }
    }
    await this.drainVoids(now)
    this.sql.exec(`DELETE FROM pair_invite_mint WHERE expires_at IS NOT NULL AND created_at <= ?`, now - OWNER_KEY_RETENTION_MS)
    const pending = this.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM pair_invite_mint WHERE expires_at IS NULL`).toArray()[0]?.at ?? null
    const voids = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM pair_invite_void`).toArray()[0]!.n
    const oldest = this.sql.exec<{ at: number | null }>(`SELECT MIN(created_at) AS at FROM pair_invite_mint WHERE expires_at IS NOT NULL`).toArray()[0]?.at ?? null
    const next = [pending === null ? null : Math.max(pending + OWNER_RECHECK_MS, now + 1_000), voids > 0 ? now + OWNER_RECHECK_MS : null, oldest === null ? null : oldest + OWNER_KEY_RETENTION_MS].filter((t): t is number => t !== null)
    if (next.length) await this.ctx.storage.setAlarm(Math.min(...next))
    else this.sql.exec(`DELETE FROM pair_invite_live`)
  }
}
