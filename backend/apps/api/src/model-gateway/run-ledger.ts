/**
 * The spend ledger of per-run gateway tokens (run-token.ts), kept in the run's own brain object
 * (ChiefBrainDO `<agent>/<conversation>`), which also knows whether the run still runs:
 * - revoke: a token works only while its run's status is "running"; the run's end or a cancel stops
 *   it at once (no wait for the token's expiry);
 * - cap: the holds and charges of one token stay within the cap it was minted with (claim `cap`), so
 *   a leaked sandbox token cannot spend more than that run's budget.
 * `hold` reserves a call's maximum price against the cap; `settle` replaces that hold with the real cost.
 *
 * Agent tokens (claim `knd: "agent"`, Lawrence 2026-10-15): valid while the hand's agent session
 * lives, not only the brain turn that started it. `open` records the token live at mint, `bind`
 * names its session once agent.start answers, `revoke` (by jti or by hand + session) ends it at once:
 * the Chief cancels the session, or the hand reports the session ended (revokeAgentSession).
 */
export type LedgerOp =
  | { readonly op: "hold"; readonly usd: number; readonly agent?: boolean }
  | { readonly op: "settle"; readonly held: number; readonly usd: number }
  | { readonly op: "open" }
  | { readonly op: "bind"; readonly hand: string; readonly session: string }
  | { readonly op: "revoke"; readonly hand?: string; readonly session?: string }
export type LedgerAnswer = { readonly ok: true; readonly used_usd: number } | { readonly ok: false; readonly code: "run_ended" | "run_budget"; readonly used_usd: number }

export const runLedger = (sql: SqlStorage, run: string, jti: string, cap: number, o: LedgerOp): LedgerAnswer => {
  sql.exec(`CREATE TABLE IF NOT EXISTS cb_runtok (jti TEXT PRIMARY KEY, run TEXT NOT NULL, used_usd REAL NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS cb_agenttok (jti TEXT PRIMARY KEY, run TEXT NOT NULL, hand TEXT, session TEXT, live INTEGER NOT NULL, at INTEGER NOT NULL)`)
  if (o.op === "open") return void sql.exec(`INSERT INTO cb_agenttok (jti, run, live, at) VALUES (?, ?, 1, ?) ON CONFLICT (jti) DO NOTHING`, jti, run, Date.now()), { ok: true, used_usd: 0 }
  if (o.op === "bind") return void sql.exec(`UPDATE cb_agenttok SET hand = ?, session = ? WHERE jti = ?`, o.hand, o.session, jti), { ok: true, used_usd: 0 }
  if (o.op === "revoke") {
    if (o.hand && o.session) sql.exec(`UPDATE cb_agenttok SET live = 0 WHERE hand = ? AND session = ?`, o.hand, o.session)
    else sql.exec(`UPDATE cb_agenttok SET live = 0 WHERE jti = ?`, jti)
    return { ok: true, used_usd: 0 }
  }
  const used = Number(sql.exec<{ used_usd: number }>(`SELECT used_usd FROM cb_runtok WHERE jti = ?`, jti).toArray()[0]?.used_usd ?? 0)
  if (o.op === "settle") {
    const next = Math.max(0, used - o.held + o.usd)
    sql.exec(`INSERT INTO cb_runtok (jti, run, used_usd) VALUES (?, ?, ?) ON CONFLICT (jti) DO UPDATE SET used_usd = excluded.used_usd`, jti, run, next)
    return { ok: true, used_usd: next }
  }
  // An agent token lives with its session (open + not revoked); a run token with its brain turn.
  const live = o.agent
    ? Number(sql.exec<{ live: number }>(`SELECT live FROM cb_agenttok WHERE jti = ?`, jti).toArray()[0]?.live ?? 0) === 1
    : sql.exec<{ status: string }>(`SELECT status FROM cb_turn WHERE id = ?`, run).toArray()[0]?.status === "running"
  if (!live) return { ok: false, code: "run_ended", used_usd: used }
  if (used + o.usd > cap) return { ok: false, code: "run_budget", used_usd: used }
  sql.exec(`INSERT INTO cb_runtok (jti, run, used_usd) VALUES (?, ?, ?) ON CONFLICT (jti) DO UPDATE SET used_usd = excluded.used_usd`, jti, run, used + o.usd)
  return { ok: true, used_usd: used + o.usd }
}
