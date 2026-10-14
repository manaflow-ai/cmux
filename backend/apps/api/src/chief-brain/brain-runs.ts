/**
 * Runs and steps of the trajectory wire (hq TRAJECTORIES shape, the same JSON as the local owner's
 * `conversation-runs-v1`), for the Durable Object Chief. A run is one turn; its id is the turn id
 * (`run_<n>`), and `turn` is the client_msg_id of the reply it posted. Steps map the OptChat entries
 * 1:1: `talk` -> a talk step, `tool` -> a tool step (running, input), `echo` -> the same tool step
 * (done, output). The brain is the only writer.
 */
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
  readonly harness: "pi-durable"
  readonly session: { readonly kind: "pi"; readonly id: string; readonly host: string }
  readonly error?: string
  /** Where the reply went: posted (with its message id), no_reply (NO_REPLY or empty), refused (with the code), none (failed turn). */
  readonly reply?: { readonly state: string; readonly message?: string }
}

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
  const kind = String(t.trigger_kind)
  const threadRoot = kind === "chief" || kind === "dm" ? (t.trigger_thread_root === null ? undefined : String(t.trigger_thread_root)) : String(t.trigger_thread_root ?? t.trigger_message)
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
    ...(status === "failed" && t.reason !== null ? { error: String(t.reason).slice(0, 2000) } : {}),
    ...(t.post === null ? {} : { reply: { state: String(t.post), ...(t.posted_message === null ? {} : { message: String(t.posted_message) }) } })
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
