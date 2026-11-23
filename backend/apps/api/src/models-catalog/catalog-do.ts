import { DurableObject } from "cloudflare:workers"
import { envForObject } from "../build-space.ts"
import type { Env, RawEnv } from "../env.ts"

/**
 * ModelCatalogDO (one instance, name "global"): the live model catalog's store (user 2026-11-19,
 * chat 40603: "a live models backend that we control"). It keeps:
 *
 * - versions: every published catalog document (schemaVersion 1, the shape web/services/model-catalog
 *   types.ts defines and acpmux reads), numbered 1, 2, 3...; the newest is served. The last
 *   KEEP_VERSIONS stay, so a bad publish rolls back by publishing an older body again.
 * - kills: the per-model kill switch, (harness, model) pairs, `*` = every harness. A kill outlives
 *   every later publish: a re-published catalog never brings a killed model back.
 * - runs: the reports of the model scout (scripts/models/scout.ts, a cmux automation), so the health
 *   route can say when it last ran, what it added and what failed.
 *
 * Bodies are a few hundred KB at most (the client refuses above 2 MB); nothing here is per user.
 */

export const KEEP_VERSIONS = 50
const KEEP_RUNS = 500

export interface StoredVersion {
  readonly version: number
  readonly body: string
  readonly publishedAt: number
  readonly note: string
}

export interface Kill {
  readonly harness: string
  readonly model: string
  readonly reason: string
  readonly at: number
  readonly by: string
}

export interface ScoutRun {
  readonly id: string
  readonly at: number
  readonly ok: boolean
  /** The run's own summary as JSON: providers read, models added, models that failed their smoke turn. */
  readonly summary: string
}

export class ModelCatalogDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) {
    // One catalog for every build (ACCOUNT_WIDE_BINDINGS): nothing here is per user or per build space.
    super(ctx, envForObject(ctx, raw))
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS versions (version INTEGER PRIMARY KEY, body TEXT NOT NULL, published_at INTEGER NOT NULL, note TEXT NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS kills (harness TEXT NOT NULL, model TEXT NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL, by TEXT NOT NULL, PRIMARY KEY (harness, model))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, at INTEGER NOT NULL, ok INTEGER NOT NULL, summary TEXT NOT NULL)`)
  }

  /** Stores `body` as the next version and returns its number. The caller validated it. */
  publish(body: string, note: string): number {
    const sql = this.ctx.storage.sql
    const last = sql.exec<{ v: number | null }>(`SELECT MAX(version) AS v FROM versions`).one().v ?? 0
    const version = last + 1
    sql.exec(`INSERT INTO versions (version, body, published_at, note) VALUES (?, ?, ?, ?)`, version, body, Date.now(), note.slice(0, 500))
    sql.exec(`DELETE FROM versions WHERE version <= ?`, version - KEEP_VERSIONS)
    return version
  }

  /** The newest version, or null before the first publish. */
  current(): StoredVersion | null {
    const row = this.ctx.storage.sql.exec<{ version: number; body: string; published_at: number; note: string }>(`SELECT version, body, published_at, note FROM versions ORDER BY version DESC LIMIT 1`).toArray()[0]
    return row ? { version: row.version, body: row.body, publishedAt: row.published_at, note: row.note } : null
  }

  /** Version numbers, times and notes, newest first (no bodies). */
  history(limit = 20): Array<Omit<StoredVersion, "body">> {
    return this.ctx.storage.sql
      .exec<{ version: number; published_at: number; note: string }>(`SELECT version, published_at, note FROM versions ORDER BY version DESC LIMIT ?`, Math.max(1, Math.min(limit, KEEP_VERSIONS)))
      .toArray()
      .map((r) => ({ version: r.version, publishedAt: r.published_at, note: r.note }))
  }

  kill(harness: string, model: string, reason: string, by: string): void {
    this.ctx.storage.sql.exec(`INSERT OR REPLACE INTO kills (harness, model, reason, at, by) VALUES (?, ?, ?, ?, ?)`, harness, model, reason.slice(0, 300), Date.now(), by.slice(0, 100))
  }

  /** Lifts a kill; true when there was one. */
  unkill(harness: string, model: string): boolean {
    return this.ctx.storage.sql.exec(`DELETE FROM kills WHERE harness = ? AND model = ?`, harness, model).rowsWritten > 0
  }

  kills(): Array<Kill> {
    return this.ctx.storage.sql.exec<{ harness: string; model: string; reason: string; at: number; by: string }>(`SELECT harness, model, reason, at, by FROM kills ORDER BY at`).toArray()
  }

  recordRun(run: ScoutRun): void {
    const sql = this.ctx.storage.sql
    sql.exec(`INSERT OR REPLACE INTO runs (id, at, ok, summary) VALUES (?, ?, ?, ?)`, run.id.slice(0, 100), run.at, run.ok ? 1 : 0, run.summary.slice(0, 64_000))
    sql.exec(`DELETE FROM runs WHERE at < (SELECT at FROM runs ORDER BY at DESC LIMIT 1 OFFSET ?)`, KEEP_RUNS - 1)
  }

  runs(limit = 20): Array<ScoutRun> {
    return this.ctx.storage.sql
      .exec<{ id: string; at: number; ok: number; summary: string }>(`SELECT id, at, ok, summary FROM runs ORDER BY at DESC LIMIT ?`, Math.max(1, Math.min(limit, KEEP_RUNS)))
      .toArray()
      .map((r) => ({ id: r.id, at: r.at, ok: r.ok === 1, summary: r.summary }))
  }
}
