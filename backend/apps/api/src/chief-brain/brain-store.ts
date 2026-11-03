import { DEFAULT_EFFORT, Effort } from "./contract.ts"
import type { ChiefProfile } from "./prompts.ts"

const EFFORTS = Effort.literals

/**
 * The Chief brain's own tables (beside the OptChat memory tables of memory.ts and pi-durable's).
 * Two kinds of ChiefBrainDO share them: the chief's settings object (name `<agent>`: the owner's
 * settings and the daily turn count) and one brain per conversation (name `<agent>/<conversation>`:
 * memory, inbox, runs), so a conversation's memory never holds another conversation's messages.
 *
 * - cb_config: who the chief is (agent, owner), whether the durable brain answers, the models and
 *   the profile (hq multi-Chief field names: role, personality, instructions); a brain keeps a copy
 *   from its settings object, refreshed at every wake and turn.
 * - cb_cursor: per conversation, the highest message seq the brain has taken (its own included).
 * - cb_inbox: conversation messages waiting for a turn, one row per message, in arrival order;
 *   `woke` marks the messages a wake named (the reply answers the newest of them).
 * - cb_turn: one row per turn, which is also the run of the trajectory wire (`run_...` id).
 * - cb_step: the run's steps (TRAJECTORIES Step JSON, upsert by step id: a tool's echo completes its tool step).
 * - oc_logged: once-per-key guard for log appends (hooks may rerun after an eviction).
 * - cb_timing: when the run's first model request went out and its first token came back (Run.timing).
 * - cb_usage: the run's model usage, summed over its model calls (model-gateway/gateway.ts).
 */
export const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS cb_config (name TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_cursor (conversation TEXT PRIMARY KEY, seq INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_inbox (n INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT UNIQUE NOT NULL, conversation TEXT NOT NULL, seq INTEGER NOT NULL, kind TEXT NOT NULL, thread_root TEXT, own_root INTEGER NOT NULL DEFAULT 1, text TEXT NOT NULL, effect_authorized INTEGER NOT NULL DEFAULT 0, woke INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'queued', turn TEXT)`,
  `CREATE TABLE IF NOT EXISTS cb_turn (id TEXT PRIMARY KEY, conversation TEXT NOT NULL, trigger_message TEXT NOT NULL, trigger_kind TEXT NOT NULL, trigger_thread_root TEXT, trigger_own_root INTEGER NOT NULL DEFAULT 1, last_seq INTEGER NOT NULL, effect_authorized INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, reason TEXT, model TEXT NOT NULL, started INTEGER NOT NULL, ended INTEGER, submitted INTEGER NOT NULL DEFAULT 0, input TEXT, reply TEXT, post TEXT, posted_message TEXT, turn_key TEXT, post_tries INTEGER NOT NULL DEFAULT 0, post_key INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS cb_step (turn TEXT NOT NULL, step TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY (turn, step))`,
  `CREATE INDEX IF NOT EXISTS cb_turn_conversation ON cb_turn (conversation, started)`,
  `CREATE TABLE IF NOT EXISTS oc_logged (key TEXT PRIMARY KEY)`,
  // Model usage per run (the model gateway's terminal messages): tokens, cache, cost; Run.usage / Run.cost_usd.
  `CREATE TABLE IF NOT EXISTS cb_timing (turn TEXT PRIMARY KEY, request_at INTEGER, first_token_at INTEGER)`,
  `CREATE TABLE IF NOT EXISTS cb_run_error (turn TEXT PRIMARY KEY, text TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_marks (turn TEXT NOT NULL, mark TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (turn, mark))`,
  `CREATE TABLE IF NOT EXISTS cb_usage (turn TEXT PRIMARY KEY, calls INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, cost_usd REAL NOT NULL)`
]

export interface BrainConfig extends ChiefProfile {
  readonly agent: string | null
  readonly owner: string | null
  readonly enabled: boolean
  readonly model: string
  /** Thinking effort of the Chief's turns (contract.ts Effort; default "low"). */
  readonly effort: string
  readonly compactor_model: string
  /** Which implementation runs this Chief's brain (contract.ts BrainImpl); the Cloud brain here is "pi". */
  readonly brain_impl: string
  /** The `chiefs` grant (brain-chiefs.ts): see, make and edit other Chiefs. Missing = on. */
  readonly chiefs: boolean
}

export const PROFILE_LIMITS = { role: 200, personality: 4_000, instructions: 32_000 } as const

/** The first problem of an owner's settings patch, or null. */
export const patchError = (patch: Partial<Record<string, unknown>>, validModel: (v: unknown) => boolean): string | null => {
  if (patch.enabled !== undefined && typeof patch.enabled !== "boolean") return "enabled must be a boolean"
  if (patch.chiefs !== undefined && typeof patch.chiefs !== "boolean") return "chiefs must be a boolean"
  for (const k of ["model", "compactor_model"]) if (patch[k] !== undefined && !validModel(patch[k])) return `${k} must be "fake", claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5, openrouter:<vendor>/<model> or a Workers AI id @cf/<vendor>/<model>`
  if (patch.effort !== undefined && !(EFFORTS as ReadonlyArray<unknown>).includes(patch.effort)) return `effort must be one of ${EFFORTS.join(", ")}`
  for (const k of ["role", "personality", "instructions"] as const) {
    const v = patch[k]
    if (v !== undefined && (typeof v !== "string" || [...v].length > PROFILE_LIMITS[k] || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(v))) return `${k} must be text of at most ${PROFILE_LIMITS[k]} characters`
  }
  return null
}

export const readConfig = (sql: SqlStorage, defaults: { model: string; compactor_model: string }): BrainConfig => {
  const rows = sql.exec<{ name: string; value: string }>(`SELECT name, value FROM cb_config`).toArray()
  const get = (k: string) => rows.find((r) => r.name === k)?.value
  return {
    agent: get("agent") ?? null,
    owner: get("owner") ?? null,
    enabled: get("enabled") === "1",
    model: get("model") ?? defaults.model,
    effort: get("effort") ?? DEFAULT_EFFORT,
    brain_impl: get("brain_impl") ?? "pi",
    compactor_model: get("compactor_model") ?? defaults.compactor_model,
    chiefs: String(get("chiefs") ?? "1") !== "0",
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
