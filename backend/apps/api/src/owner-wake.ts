import type { SqlStore } from "@cmux/ownership"

/** The earlier of two optional times; null when both are null. */
export const earliest = (a: number | null, b: number | null): number | null => (a === null ? b : b === null ? a : Math.min(a, b))

/**
 * Records one more failed owner wake in do_wake and returns when to retry: exponential backoff
 * capped at maxBackoffMs, so past-due work that keeps failing does not refire the alarm at once.
 */
export function recordWakeFailure(store: SqlStore, stream: string, error: unknown, maxBackoffMs: number): number {
  const attempts = (store.exec<{ attempts: number }>(`SELECT attempts FROM do_wake WHERE id = 1`)[0]?.attempts ?? 0) + 1
  store.exec(`INSERT INTO do_wake (id, attempts) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET attempts = excluded.attempts`, attempts)
  console.error(JSON.stringify({ msg: "owner wake failed", stream, attempts, error: String(error) }))
  return Date.now() + Math.min(maxBackoffMs, 1000 * 2 ** attempts)
}
