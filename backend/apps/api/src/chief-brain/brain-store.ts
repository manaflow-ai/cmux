import type { ChiefProfile } from "./prompts.ts"

/**
 * The Chief brain's own tables (beside the OptChat memory tables of memory.ts and pi-durable's).
 * One brain per chief, so every row belongs to that chief.
 *
 * - cb_config: who the chief is (agent, owner), whether the durable brain answers, the models and
 *   the profile (hq multi-Chief field names: role, personality, instructions).
 * - cb_cursor: per conversation, the highest message seq the brain has taken (its own included).
 * - cb_inbox: conversation messages waiting for a turn, one row per message, in arrival order.
 * - cb_turn: one row per turn, which is also the run of the trajectory wire (`run_...` id).
 * - cb_step: the run's steps (TRAJECTORIES Step JSON, upsert by step id: a tool's echo completes its tool step).
 * - oc_logged: once-per-key guard for log appends (hooks may rerun after an eviction).
 */
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS cb_config (name TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_cursor (conversation TEXT PRIMARY KEY, seq INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_inbox (n INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT UNIQUE NOT NULL, conversation TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, thread_root TEXT, text TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued', turn TEXT)`,
  `CREATE TABLE IF NOT EXISTS cb_turn (id TEXT PRIMARY KEY, conversation TEXT NOT NULL, trigger_message TEXT NOT NULL, trigger_kind TEXT NOT NULL, trigger_thread_root TEXT, last_seq INTEGER NOT NULL, status TEXT NOT NULL, reason TEXT, model TEXT NOT NULL, started INTEGER NOT NULL, ended INTEGER, submitted INTEGER NOT NULL DEFAULT 0, input TEXT, reply TEXT, post TEXT, posted_message TEXT, turn_key TEXT, post_tries INTEGER NOT NULL DEFAULT 0, post_key INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS cb_step (turn TEXT NOT NULL, step TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY (turn, step))`,
  `CREATE INDEX IF NOT EXISTS cb_turn_conversation ON cb_turn (conversation, started)`,
  `CREATE TABLE IF NOT EXISTS oc_logged (key TEXT PRIMARY KEY)`
]

export interface BrainConfig extends ChiefProfile {
  readonly agent: string | null
  readonly owner: string | null
  readonly enabled: boolean
  readonly model: string
  readonly compactor_model: string
}

export const PROFILE_LIMITS = { role: 200, personality: 4_000, instructions: 32_000 } as const

export const readConfig = (sql: SqlStorage, defaults: { model: string; compactor_model: string }): BrainConfig => {
  const rows = sql.exec<{ name: string; value: string }>(`SELECT name, value FROM cb_config`).toArray()
  const get = (k: string) => rows.find((r) => r.name === k)?.value
  return {
    agent: get("agent") ?? null,
    owner: get("owner") ?? null,
    enabled: get("enabled") === "1",
    model: get("model") ?? defaults.model,
    compactor_model: get("compactor_model") ?? defaults.compactor_model,
    display_name: get("display_name") ?? "Chief",
    role: get("role") ?? "",
    personality: get("personality") ?? "",
    instructions: get("instructions") ?? ""
  }
}

export const writeConfig = (sql: SqlStorage, change: Readonly<Record<string, string | undefined>>): void => {
  for (const [k, v] of Object.entries(change)) {
    if (v === undefined) continue
    sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, k, v)
  }
}
