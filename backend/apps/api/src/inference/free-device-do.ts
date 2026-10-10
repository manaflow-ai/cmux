import { DurableObject } from "cloudflare:workers"
import { verifyAppAttestData, type AppAttestKey } from "@cmux/home-core/user"
import type { AttestedKey } from "../app-attest.ts"
import type { Env } from "../env.ts"
import { utcDay } from "./spend-guard-do.ts"

/**
 * FreeDeviceDO: one per App Attest key (name = the key id), the free tier's per-install state
 * (cx-dna4.3): the attested public key and its counter, the day's token quota with open
 * reservations, and a per-minute request window. A request reserves its token bound before the
 * upstream call and settles with the real count; an unsettled reservation counts in full.
 */

export type FreeAdmit = { readonly ok: true } | { readonly ok: false; readonly code: "free.quota" | "free.rate" | "free.unknown_device"; readonly retryAfterS?: number }

const intVar = (v: string | undefined, d: number) => {
  const n = Number(v)
  return Number.isInteger(n) && n > 0 ? n : d
}

export class FreeDeviceDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS device (id INTEGER PRIMARY KEY CHECK (id = 1), jwk TEXT NOT NULL, app_id_hash TEXT NOT NULL, counter INTEGER NOT NULL, platform TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS usage (day TEXT PRIMARY KEY, tokens INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS open (id TEXT PRIMARY KEY, day TEXT NOT NULL, tokens INTEGER NOT NULL, at INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS minute (id INTEGER PRIMARY KEY CHECK (id = 1), minute INTEGER NOT NULL, n INTEGER NOT NULL)`)
  }

  private device(): AppAttestKey | undefined {
    const row = this.ctx.storage.sql.exec<{ jwk: string; app_id_hash: string; counter: number }>(`SELECT jwk, app_id_hash, counter FROM device WHERE id = 1`).toArray()[0]
    return row ? { jwk: JSON.parse(row.jwk), app_id_hash: row.app_id_hash, counter: Number(row.counter) } : undefined
  }

  async known(): Promise<boolean> {
    return this.device() !== undefined
  }

  /** Stores the attested key once. The same key again is a no-op; a different key under this id is refused. */
  async register(key: AttestedKey, platform: string): Promise<boolean> {
    const have = this.device()
    if (have) return JSON.stringify(have.jwk) === JSON.stringify(key.jwk) && have.app_id_hash === key.app_id_hash
    this.ctx.storage.sql.exec(`INSERT INTO device (id, jwk, app_id_hash, counter, platform, created_at) VALUES (1, ?, ?, 0, ?, ?)`, JSON.stringify(key.jwk), key.app_id_hash, platform, Date.now())
    return true
  }

  /** An App Attest assertion over `clientData` with a counter above the stored one; stores the new counter. */
  async assert(clientData: Uint8Array, assertion: string): Promise<boolean> {
    const key = this.device()
    if (!key) return false
    const r = verifyAppAttestData(key, clientData, assertion)
    if (!r.ok) return false
    this.ctx.storage.sql.exec(`UPDATE device SET counter = ? WHERE id = 1 AND counter < ?`, r.counter, r.counter)
    return true
  }

  async admit(id: string, tokenBound: number, now = Date.now()): Promise<FreeAdmit> {
    if (!this.device()) return { ok: false, code: "free.unknown_device" }
    const sql = this.ctx.storage.sql
    const perMinute = intVar(this.env.INFERENCE_FREE_PER_MINUTE, 20)
    const minute = Math.floor(now / 60_000)
    const w = sql.exec<{ minute: number; n: number }>(`SELECT minute, n FROM minute WHERE id = 1`).toArray()[0]
    const n = w && Number(w.minute) === minute ? Number(w.n) : 0
    if (n >= perMinute) return { ok: false, code: "free.rate", retryAfterS: 60 - Math.floor((now / 1000) % 60) }
    const day = utcDay(now)
    // Reservations older than an hour count as spent (a lost settle never frees quota).
    sql.exec(`INSERT INTO usage (day, tokens) SELECT day, SUM(tokens) FROM open WHERE at < ? GROUP BY day ON CONFLICT (day) DO UPDATE SET tokens = tokens + excluded.tokens`, now - 3600_000)
    sql.exec(`DELETE FROM open WHERE at < ?`, now - 3600_000)
    const used = Number(sql.exec<{ t: number | null }>(`SELECT tokens AS t FROM usage WHERE day = ?`, day).toArray()[0]?.t ?? 0)
    const open = Number(sql.exec<{ t: number | null }>(`SELECT SUM(tokens) AS t FROM open WHERE day = ?`, day).toArray()[0]?.t ?? 0)
    if (used + open + tokenBound > intVar(this.env.INFERENCE_FREE_DAILY_TOKENS, 300_000)) return { ok: false, code: "free.quota" }
    sql.exec(`INSERT INTO minute (id, minute, n) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET minute = excluded.minute, n = excluded.n`, minute, n + 1)
    sql.exec(`INSERT OR REPLACE INTO open (id, day, tokens, at) VALUES (?, ?, ?, ?)`, id, day, tokenBound, now)
    sql.exec(`DELETE FROM usage WHERE day < ?`, utcDay(now - 7 * 86_400_000))
    return { ok: true }
  }

  async settle(id: string, tokens: number): Promise<void> {
    const sql = this.ctx.storage.sql
    const row = sql.exec<{ day: string }>(`SELECT day FROM open WHERE id = ?`, id).toArray()[0]
    if (!row) return
    this.ctx.storage.transactionSync(() => {
      sql.exec(`INSERT INTO usage (day, tokens) VALUES (?, ?) ON CONFLICT (day) DO UPDATE SET tokens = tokens + excluded.tokens`, row.day, Math.max(0, Math.round(tokens)))
      sql.exec(`DELETE FROM open WHERE id = ?`, id)
    })
  }
}
