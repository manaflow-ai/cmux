/**
 * Runs and steps of the trajectory wire (hq TRAJECTORIES shape, the same JSON as the local owner's
 * `conversation-runs-v1`), for the Durable Object Chief. A run is one turn; its id is the turn id
 * (`run_<n>`), and `turn` is the client_msg_id of the reply it posted. Steps map the OptChat entries
 * 1:1: `talk` -> a talk step, `tool` -> a tool step (running, input), `echo` -> the same tool step
 * (done, output). The brain is the only writer.
 */
import { oneLine } from "./brain-text.ts"

export type StepKind = "talk" | "thought" | "tool" | "note"

export interface Step {
  readonly id: string
  readonly seq: number
  readonly at: number
  readonly kind: StepKind
  readonly status?: "running" | "done" | "failed"
  readonly text?: string
  readonly truncated?: boolean
  readonly tool?: { readonly name: string; readonly input?: unknown; readonly output?: string; readonly started_at?: number; readonly ended_at?: number }
  /** ms epoch: when the step ended (a tool step at its result, a talk step at its final text); `at` is its first write. */
  readonly ended_at?: number
}

export interface Run {
  readonly id: string
  readonly conversation: string
  readonly author: string
  readonly turn?: string
  readonly answers: ReadonlyArray<string>
  readonly thread_root?: string
  readonly status: "running" | "done" | "failed" | "cancelled"
  readonly started_at: number
  readonly ended_at?: number
  readonly step_count: number
  readonly last_step_seq: number
  readonly model: string
  readonly harness: "pi-durable" | "pi-durable-d"
  readonly session: { readonly kind: "pi"; readonly id: string; readonly host: string }
  readonly error?: string
  /** A subagent's run (brain-spawn.ts): the run that spawned it. */
  readonly parent_run?: string
  /** Where the reply went: posted (with its message id), no_reply (NO_REPLY or empty), refused (with the code), none (failed turn). */
  readonly reply?: { readonly state: string; readonly message?: string }
  /** Model tokens of the run (cache_read / (input + cache_read + cache_write) = cache hit) and its provider cost. */
  readonly usage?: { readonly input: number; readonly output: number; readonly cache_read: number; readonly cache_write: number; readonly calls: number }
  readonly cost_usd?: number
  /**
   * ms epoch: first model request, first token of the run (its first output: text, thinking or a tool call; with
   * started_at: wake path vs. model time); continuation_at / continuation_first_token_at: the hands continuation;
   * step marks of the turn's start (brain-turn.ts): count_at, auth_at, paid_at, pi_at, submit_at.
   */
  readonly timing?: { readonly regions?: ReadonlyArray<string>; readonly count_at?: number; readonly boot_at?: number; readonly mux_at?: number; readonly life_at?: number; readonly reserved_at?: number; readonly upstream_at?: number; readonly headers_at?: number; readonly auth_at?: number; readonly paid_at?: number; readonly pi_at?: number; readonly submit_at?: number; readonly wake_at?: number; readonly admitted_at?: number; readonly settled_at?: number; readonly request_at?: number; readonly first_token_at?: number; readonly continuation_at?: number; readonly continuation_first_token_at?: number }
}

/**
 * Wake-path marks (ms epoch): `wake` (the brain got the wake), `admitted` (the turn passed the
 * settings object and credits), `settled` (the memory view was ready); kept until the next turn
 * opens, then stored with it (cb_timing2). With started_at, request_at and first_token_at they split
 * the time from a person's message to the first token.
 */
export const markPending = (sql: SqlStorage, mark: "wake" | "admitted" | "settled" | "boot" | "life" | "mux", at = Date.now()): void =>
  void sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = ${mark === "wake" || mark === "boot" || mark === "life" || mark === "mux" ? "CASE WHEN cb_config.value = '' THEN excluded.value ELSE cb_config.value END" : "excluded.value"}`, `mark.${mark}`, String(at))
export const flushMarks = (sql: SqlStorage, turn: string): void => {
  for (const m of ["mux", "boot", "life", "wake", "admitted", "settled"]) {
    const v = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `mark.${m}`).toArray()[0]?.value
    // A mark left by a wake that started no turn (skipped, nothing new) is older than this turn's wake path: dropped.
    if (v && Date.now() - Number(v) < 60_000) sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, turn, m, Number(v))
    sql.exec(`UPDATE cb_config SET value = '' WHERE name = ?`, `mark.${m}`)
  }
}

/** A failed run's error: its reason, and the newest model error the gateway saw (the route's message, no secret). */
export const runError = (sql: SqlStorage, id: string): string | undefined => sql.exec<{ text: string }>(`SELECT text FROM cb_run_error WHERE turn = ?`, id).toArray()[0]?.text
const errorOf = (sql: SqlStorage, id: string, reason: string): string => {
  const model = runError(sql, id)
  return (model && !reason.includes(model) ? `${reason}: ${model}` : reason).slice(0, 2000)
}

/** Adds one model call's usage to its run. */
export const addUsage = (sql: SqlStorage, turn: string, u: { input: number; output: number; cache_read: number; cache_write: number; cost_usd: number }): void =>
  void sql.exec(
    `INSERT INTO cb_usage (turn, calls, input, output, cache_read, cache_write, cost_usd) VALUES (?, 1, ?, ?, ?, ?, ?) ON CONFLICT (turn) DO UPDATE SET calls = calls + 1, input = input + excluded.input, output = output + excluded.output, cache_read = cache_read + excluded.cache_read, cache_write = cache_write + excluded.cache_write, cost_usd = cost_usd + excluded.cost_usd`,
    turn, Math.round(u.input), Math.round(u.output), Math.round(u.cache_read), Math.round(u.cache_write), u.cost_usd
  )

/** A step change: fields to set on the step with this id (created at the next seq when new). */
export type StepPatch = Omit<Step, "seq" | "at"> & { readonly at?: number }

const TEXT_MAX = 32 * 1024
const INPUT_MAX = 16 * 1024

/** Head and tail kept past `max` characters, as the wire asks. */
export const clip = (text: string, max = TEXT_MAX): { text: string; truncated?: true } => {
  if (text.length <= max) return { text }
  const half = Math.floor(max / 2)
  return { text: `${text.slice(0, half)}\n[... ${text.length - max} characters cut ...]\n${text.slice(-half)}`, truncated: true }
}

/** A tool input as JSON when it fits, else a string head. */
export const clipInput = (input: unknown): unknown => {
  const json = JSON.stringify(input ?? null)
  return json.length <= INPUT_MAX ? input : json.slice(0, INPUT_MAX)
}

/** Upserts one step of `turn` (merging into an existing step with the same id) and returns it. */
export const upsertStep = (sql: SqlStorage, turn: string, patch: StepPatch, now: number): Step => {
  const row = sql.exec<{ seq: number; body: string }>(`SELECT seq, body FROM cb_step WHERE turn = ? AND step = ?`, turn, patch.id).toArray()[0]
  if (row) {
    const old = JSON.parse(row.body) as Step
    const next: Step = { ...old, ...patch, at: old.at, seq: old.seq, ...(old.tool || patch.tool ? { tool: { ...old.tool, ...patch.tool } as NonNullable<Step["tool"]> } : {}) }
    sql.exec(`UPDATE cb_step SET body = ? WHERE turn = ? AND step = ?`, JSON.stringify(next), turn, patch.id)
    return next
  }
  const seq = Number(sql.exec<{ n: number }>(`SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM cb_step WHERE turn = ?`, turn).one().n)
  const step: Step = { ...patch, seq, at: patch.at ?? now }
  sql.exec(`INSERT INTO cb_step (turn, step, seq, body) VALUES (?, ?, ?, ?)`, turn, patch.id, seq, JSON.stringify(step))
  return step
}

export const readSteps = (sql: SqlStorage, turn: string, afterSeq = 0, limit = 500): Array<Step> =>
  sql.exec<{ body: string }>(`SELECT body FROM cb_step WHERE turn = ? AND seq > ? ORDER BY seq LIMIT ?`, turn, afterSeq, limit).toArray().map((r) => JSON.parse(r.body) as Step)

/** The text of the run's last talk step: the reply. */
export const lastTalk = (sql: SqlStorage, turn: string): string => {
  const talks = readSteps(sql, turn, 0, 2000).filter((s) => s.kind === "talk" && s.text)
  return talks.at(-1)?.text?.trim() ?? ""
}

const STATUS = new Set(["running", "done", "failed", "cancelled"])

export const readRun = (sql: SqlStorage, agent: string, id: string): Run | null => {
  const t = sql.exec<Record<string, SqlStorageValue>>(`SELECT * FROM cb_turn WHERE id = ?`, id).toArray()[0]
  if (!t) return null
  const counts = sql.exec<{ n: number; last: number | null }>(`SELECT COUNT(*) AS n, MAX(seq) AS last FROM cb_step WHERE turn = ?`, id).one()
  const answers = sql.exec<{ message: string }>(`SELECT message FROM cb_inbox WHERE turn = ? ORDER BY n`, id).toArray().map((r) => String(r.message))
  const status = String(t.status)
  const u = sql.exec<{ calls: number; input: number; output: number; cache_read: number; cache_write: number; cost_usd: number }>(`SELECT calls, input, output, cache_read, cache_write, cost_usd FROM cb_usage WHERE turn = ?`, id).toArray()[0]
  const tm = sql.exec<{ request_at: number | null; first_token_at: number | null }>(`SELECT request_at, first_token_at FROM cb_timing WHERE turn = ?`, id).toArray()[0]
  const markRows = sql.exec<{ mark: string; at: number }>(`SELECT mark, at FROM cb_marks WHERE turn = ? ORDER BY at`, id).toArray()
  // `region:<name>` marks: the upstream regions that answered the run's model calls, in order.
  const regions = markRows.filter((r) => String(r.mark).startsWith("region:")).map((r) => String(r.mark).slice(7))
  const marks: Record<string, unknown> = Object.fromEntries(markRows.filter((r) => !String(r.mark).startsWith("region:")).map((r) => [`${r.mark}_at`, Number(r.at)]))
  if (regions.length > 0) marks.regions = regions
  const kind = String(t.trigger_kind)
  const threadRoot = kind === "spawn" ? undefined : oneLine(kind) ? (t.trigger_thread_root === null ? undefined : String(t.trigger_thread_root)) : String(t.trigger_thread_root ?? t.trigger_message)
  return {
    id,
    conversation: String(t.conversation),
    author: agent,
    ...(t.turn_key === null ? {} : { turn: String(t.turn_key) }),
    answers,
    ...(threadRoot ? { thread_root: threadRoot } : {}),
    status: (STATUS.has(status) ? status : "failed") as Run["status"],
    started_at: Number(t.started),
    ...(t.ended === null ? {} : { ended_at: Number(t.ended) }),
    step_count: Number(counts.n),
    last_step_seq: Number(counts.last ?? 0),
    model: String(t.model),
    harness: "pi-durable",
    session: { kind: "pi", id, host: "cloud" },
    ...(kind === "spawn" ? { parent_run: String(t.trigger_message) } : {}),
    ...(status === "failed" && t.reason !== null ? { error: errorOf(sql, id, String(t.reason)) } : {}),
    ...(t.post === null ? {} : { reply: { state: String(t.post), ...(t.posted_message === null ? {} : { message: String(t.posted_message) }) } }),
    ...(tm || Object.keys(marks).length > 0 ? { timing: { ...marks, ...(!tm || tm.request_at === null ? {} : { request_at: Number(tm.request_at) }), ...(!tm || tm.first_token_at === null ? {} : { first_token_at: Number(tm.first_token_at) }) } } : {}),
    ...(u ? { usage: { input: Number(u.input), output: Number(u.output), cache_read: Number(u.cache_read), cache_write: Number(u.cache_write), calls: Number(u.calls) }, cost_usd: Number(u.cost_usd) } : {})
  }
}

/** The conversation's runs of this chief, newest first. */
export const readRuns = (sql: SqlStorage, agent: string, conversation: string, before: number | undefined, limit: number): { runs: Array<Run>; has_more: boolean } => {
  const rows = sql
    .exec<{ id: string }>(`SELECT id FROM cb_turn WHERE conversation = ? AND started < ? ORDER BY started DESC LIMIT ?`, conversation, before ?? Number.MAX_SAFE_INTEGER, limit + 1)
    .toArray()
  const runs = rows.slice(0, limit).flatMap((r) => readRun(sql, agent, String(r.id)) ?? [])
  return { runs, has_more: rows.length > limit }
}
