import { expect } from "bun:test"
import type mysql from "mysql2/promise"
import { mirrorStatements } from "../../apps/api/src/credits-mirror.ts"

/**
 * The credits mirror's SQL (apps/api/src/credits-mirror.ts) on a real database: scratch MySQL 8.4
 * (test-mysql) and the PlanetScale Vitess development branch (test-vitess), on test-only team ids.
 */
const entry = (seq: number, key: string, kind: string, micros: number, at: number) => ({ key, kind, micros, cost_micros: kind === "charge" ? -micros : null, chief: kind === "charge" ? "agent_mirror" : null, conversation: null, actor: kind === "charge" ? null : "test", reason: null, corrects: null, at, seq })

export const cleanup = async (db: mysql.Connection, team: string) => {
  for (const t of ["credit_ledger", "credit_balance", "team_billing_customer"]) await db.query(`DELETE FROM ${t} WHERE team_id = ?`, [team])
}

const apply = async (db: mysql.Connection, statements: Array<[string, Array<unknown>]>) => {
  for (const [q, v] of statements) await db.query(q, v)
}

export const creditMirrorCases = async (db: mysql.Connection, team: string) => {
  await cleanup(db, team)
  const t0 = Date.UTC(2026, 9, 15, 12, 0, 0, 123)
  const e1 = entry(1, "grant:mirror-1", "grant", 500_000_000, t0)
  const e2 = entry(2, "charge:brain:task:0", "charge", -15_000, t0 + 1000)
  const first = mirrorStatements(team, [e1, e2], { balance: 499_985_000, held: 22_000, version: 4, last_seq: 2, changed_at: t0 + 1000 }, [{ mode: "test", customer: "cus_test_mirror1", at: t0 }])
  await apply(db, first)
  // The same run again (an answer lost after the database committed) changes nothing.
  await apply(db, first)
  const [ledger] = (await db.query("SELECT entry_key, kind, micros, cost_micros, chief, seq, at FROM credit_ledger WHERE team_id = ? ORDER BY seq", [team])) as any
  expect(ledger).toEqual([
    { entry_key: "grant:mirror-1", kind: "grant", micros: 500_000_000, cost_micros: null, chief: null, seq: 1, at: "2026-10-15 12:00:00.123" },
    { entry_key: "charge:brain:task:0", kind: "charge", micros: -15_000, cost_micros: 15_000, chief: "agent_mirror", seq: 2, at: "2026-10-15 12:00:01.123" }
  ])
  const balance = async () => ((await db.query("SELECT balance_micros, held_micros, last_seq, version FROM credit_balance WHERE team_id = ?", [team])) as any)[0][0]
  expect(await balance()).toEqual({ balance_micros: 499_985_000, held_micros: 22_000, last_seq: 2, version: 4 })
  // A newer snapshot wins; an older one (a slow run that finished late) never overwrites it.
  await apply(db, mirrorStatements(team, [], { balance: 499_985_000, held: 0, version: 6, last_seq: 2, changed_at: t0 + 2000 }, []))
  await apply(db, mirrorStatements(team, [], { balance: 1, held: 999, version: 5, last_seq: 2, changed_at: t0 + 1500 }, []))
  expect(await balance()).toEqual({ balance_micros: 499_985_000, held_micros: 0, last_seq: 2, version: 6 })
  // The team's customer is set once; a different later value does not replace it.
  await apply(db, mirrorStatements(team, [], { balance: 499_985_000, held: 0, version: 7, last_seq: 2, changed_at: t0 + 3000 }, [{ mode: "test", customer: "cus_test_other", at: t0 + 3000 }]))
  const [customers] = (await db.query("SELECT mode, customer_id FROM team_billing_customer WHERE team_id = ?", [team])) as any
  expect(customers).toEqual([{ mode: "test", customer_id: "cus_test_mirror1" }])
  // A seq another key already has (a DO whose storage was reset) fails loudly; nothing is written.
  const clash = entry(1, "grant:after-reset", "grant", 1, t0 + 5000)
  const [[q, v]] = mirrorStatements(team, [clash], null, [])
  await expect(db.query(q, v)).rejects.toThrow()
  // A value too long for its column fails loudly too (not truncated).
  const [[q2, v2]] = mirrorStatements(team, [{ ...entry(9, "grant:long-reason", "grant", 1, t0 + 6000), reason: "x".repeat(300) }], null, [])
  await expect(db.query(q2, v2)).rejects.toThrow()
  // The ledger sums to the balance the DO reported.
  const [[sum]] = (await db.query("SELECT CAST(SUM(micros) AS SIGNED) AS s FROM credit_ledger WHERE team_id = ?", [team])) as any
  expect(Number(sum.s)).toBe(499_985_000)
  await cleanup(db, team)
}
