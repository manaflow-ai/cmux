import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Env } from "../env.ts"
import type { Principal } from "@cmux/ownership"
import { liveFrame, postWork, runChanged } from "./brain-io.ts"
import type { BrainConfig } from "./brain-store.ts"
import { replyTarget } from "./brain-text.ts"

/**
 * `spawn(tasks[])`: subagents of a Cloud Chief, with no hand (unii parity gap 4, hq-1f SPAWN-HANDOFF).
 *
 * - The tool returns the children's names at once and never waits for them. Each task runs as its own
 *   ChiefBrainDO (name `<agent>/<conversation>:spawn:<n>`, the "child" role: a fresh context of the task
 *   and the brief, its own model loop through the model gateway, hands allowed, no spawn: depth 1).
 * - Parallelism per Chief is bounded in the Chief's settings object (`<agent>`, table cb_spawn_slot):
 *   at most CHIEF_SPAWN_MAX (default 4) children run; the rest wait there and start as slots free.
 * - A child's report goes to the parent brain (`spawnReport`, stored in cb_spawn first), which posts it
 *   as a text-less `work` card as the Chief (no loop-guard turn) and queues it as a woken inbox row: it
 *   joins the running turn through the steer path, or it starts a turn.
 * - The child's run id is `sub_<n>`; the conversation's runs route reads it from the child object.
 * - The child's hands caller and agent tokens name `<conversation>:spawn:<n>` as their conversation, so
 *   the gateway ledger and a hand's session-end revoke address the child object (run-token.ts).
 */
export const SPAWN_SCHEMA = [
  // Parent brain: one row per child it spawned (`call`, `i` make a replayed tool call commit once).
  `CREATE TABLE IF NOT EXISTS cb_spawn (n INTEGER PRIMARY KEY AUTOINCREMENT, call TEXT NOT NULL, i INTEGER NOT NULL, name TEXT NOT NULL, parent_run TEXT NOT NULL, conversation TEXT NOT NULL, kind TEXT NOT NULL, thread_root TEXT, task TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued', created INTEGER NOT NULL, ended INTEGER, report TEXT, posted INTEGER NOT NULL DEFAULT 0, UNIQUE (call, i))`,
  // Settings object: the Chief's child slots (waiting or running), with each child's start payload.
  `CREATE TABLE IF NOT EXISTS cb_spawn_slot (child TEXT PRIMARY KEY, state TEXT NOT NULL, at INTEGER NOT NULL, start TEXT NOT NULL)`
]

/** Tasks per spawn call. */
export const SPAWN_MAX_TASKS = 8
const TASK_MAX = 8_000
const BRIEF_MAX = 16_000
/** A report the parent reads (the view doc: messages up to 30,000 characters). */
const REPORT_MAX = 30_000
/** Work-card preview limit (home-core MAX_PREVIEW_BYTES). */
const PREVIEW_BYTES = 4_096
/** A running slot older than this is free again (a child run is bounded by TURN_MS = 10 min). */
export const SLOT_STALE_MS = 12 * 60_000

export const spawnMax = (env: Env): number => {
  const n = Math.floor(Number(env.CHIEF_SPAWN_MAX ?? "4"))
  return Number.isFinite(n) && n >= 1 ? Math.min(n, 32) : 4
}

/** What a child object needs to run (stored in its cb_config `spawn`). */
export interface ChildStart {
  readonly agent: string
  readonly owner: string
  readonly conversation: string
  readonly n: number
  readonly name: string
  readonly task: string
  readonly brief: string
  readonly model: string
  readonly effort: string
  readonly display_name: string
  readonly parent_run: string
}

/** The child's conversation key: its object name suffix and its ledger conversation. */
export const childKey = (conversation: string, n: number) => `${conversation}:spawn:${n}`
export const childRunId = (n: number) => `sub_${n}`
export const childObject = (agent: string, conversation: string, n: number) => `${agent}/${childKey(conversation, n)}`

const NAMES = ["Ada", "Bo", "Cy", "Dee", "Eli", "Fay", "Gus", "Hal", "Ivy", "Jo", "Kit", "Lou", "Max", "Nell", "Oto", "Pia"]
const nameOf = (n: number) => `${NAMES[(n - 1) % NAMES.length]}${n > NAMES.length ? Math.floor((n - 1) / NAMES.length) + 1 : ""}`

export const readChild = (sql: SqlStorage): ChildStart | null => {
  const v = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'spawn'`).toArray()[0]?.value
  return v ? (JSON.parse(v) as ChildStart) : null
}

/** The child's system prompt (no view, no memory: the task is its whole context). */
export const childPrompt = (s: ChildStart): string =>
  `You are ${s.name}, a subagent of ${s.display_name}, a Chief (an AI agent that works for a person in
cmux conversations). You do ONE task and answer with a short report: the result first, then in a few
lines how you got it and anything the Chief must check. You see no conversation and keep no memory;
the task and the brief below are your whole context. Use your tools when the task needs them. Your
whole answer is the report: it goes to the Chief, not to the person.`

export const childInput = (s: ChildStart): Array<string> => [`Task:\n${s.task}${s.brief ? `\n\nBrief from ${s.display_name}:\n${s.brief}` : ""}`]

export const SPAWN_DESCRIPTION =
  "Start subagents that work in parallel, one per task, each with a fresh context (the task text and the brief only: put every fact a task needs in it). Returns their names at once; never waits. Each subagent's report comes back to you later as a work message \"[Name] report\". Do not wait for them and do not do their tasks yourself; you may answer the person meanwhile. Up to 8 tasks per call."

const Args = Type.Object({
  tasks: Type.Array(Type.String({ minLength: 1, maxLength: TASK_MAX }), { minItems: 1, maxItems: SPAWN_MAX_TASKS, description: "One self-contained task per subagent." }),
  brief: Type.Optional(Type.String({ maxLength: BRIEF_MAX, description: "Shared context every subagent gets with its task." }))
})
type ArgsT = { tasks: Array<string>; brief?: string }

/** The turn's thread: where its reply and its children's reports go. */
export const turnThread = (kind: string, message: string, root: string | null): string | null => replyTarget(kind, message, root).thread_root ?? null

export interface SpawnHost {
  readonly env: Env
  readonly sql: SqlStorage
  readonly transaction: (f: () => void) => void
  /** The running turn (run id and conversation), or undefined between turns. */
  turn(): { run: string; conversation: string } | undefined
  config(): BrainConfig
  /** True in a child object: no deeper spawn. */
  isChild(): boolean
  /** The settings object queues the children and starts as many as its cap allows. */
  enqueue(items: ReadonlyArray<ChildStart>): Promise<{ running: number; waiting: number }>
  /** The live "N subagents" line changed. */
  changed(conversation: string): void
}

export const spawnTool = (host: SpawnHost): ToolRegistration<typeof Args> => ({
  name: "spawn",
  description: SPAWN_DESCRIPTION,
  parameters: Args,
  replay: "safe",
  execute: async (raw, api) => {
    const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] })
    const args = raw as ArgsT
    if (host.isChild()) return text("spawn: a subagent cannot start subagents; do the task yourself.")
    const turn = host.turn()
    const cfg = host.config()
    if (!turn || !cfg.agent || !cfg.owner) return text("spawn: no running turn")
    const tasks = (args.tasks ?? []).map((t) => String(t).trim()).filter(Boolean).slice(0, SPAWN_MAX_TASKS)
    if (tasks.length === 0) return text("spawn: give at least one task")
    const t = host.sql.exec<{ trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; model: string }>(`SELECT trigger_message, trigger_kind, trigger_thread_root, model FROM cb_turn WHERE id = ?`, turn.run).toArray()[0]
    if (!t) return text("spawn: no running turn")
    const thread = turnThread(t.trigger_kind, t.trigger_message, t.trigger_thread_root)
    const call = String(api.callId)
    const now = Date.now()
    host.transaction(() => {
      tasks.forEach((task, i) =>
        host.sql.exec(
          `INSERT INTO cb_spawn (call, i, name, parent_run, conversation, kind, thread_root, task, created) VALUES (?, ?, '', ?, ?, ?, ?, ?, ?) ON CONFLICT (call, i) DO NOTHING`,
          call, i, turn.run, turn.conversation, t.trigger_kind, thread, task, now
        )
      )
      for (const r of host.sql.exec<{ n: number }>(`SELECT n FROM cb_spawn WHERE call = ? AND name = ''`, call).toArray()) host.sql.exec(`UPDATE cb_spawn SET name = ? WHERE n = ?`, nameOf(r.n), r.n)
    })
    const rows = host.sql.exec<{ n: number; name: string; task: string; state: string }>(`SELECT n, name, task, state FROM cb_spawn WHERE call = ? ORDER BY i`, call).toArray()
    const model = host.env.CHIEF_SPAWN_MODEL || t.model
    const items: Array<ChildStart> = rows
      .filter((r) => r.state === "queued")
      .map((r) => ({ agent: cfg.agent!, owner: cfg.owner!, conversation: turn.conversation, n: r.n, name: r.name, task: r.task, brief: args.brief?.trim() ?? "", model, effort: cfg.effort, display_name: cfg.display_name, parent_run: turn.run }))
    let note = ""
    if (items.length > 0) {
      const r = await host.enqueue(items)
      host.sql.exec(`UPDATE cb_spawn SET state = 'enqueued' WHERE call = ? AND state = 'queued'`, call)
      if (r.waiting > 0) note = ` ${r.waiting} wait for a free slot (at most ${spawnMax(host.env)} run at once).`
    }
    host.changed(turn.conversation)
    return text(`Started ${rows.length} subagent${rows.length === 1 ? "" : "s"}: ${rows.map((r) => r.name).join(", ")}.${note} Each report comes back to you as a work message "[Name] ..."; do not wait for them.`)
  }
})

// ------------------------------------------------------------------ settings object: slots

const childStub = (env: Env, s: ChildStart) =>
  env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(childObject(s.agent, s.conversation, s.n))) as unknown as { spawnStart(s: ChildStart): Promise<{ ended: boolean }> }

export const slotEnqueue = (sql: SqlStorage, items: ReadonlyArray<ChildStart>, now: number): void => {
  for (const s of items) sql.exec(`INSERT INTO cb_spawn_slot (child, state, at, start) VALUES (?, 'waiting', ?, ?) ON CONFLICT (child) DO NOTHING`, childObject(s.agent, s.conversation, s.n), now, JSON.stringify(s))
}

export const slotCounts = (sql: SqlStorage): { running: number; waiting: number } => {
  const r = sql.exec<{ running: number; waiting: number }>(`SELECT COALESCE(SUM(state = 'running'), 0) AS running, COALESCE(SUM(state = 'waiting'), 0) AS waiting FROM cb_spawn_slot`).one()
  return { running: Number(r.running), waiting: Number(r.waiting) }
}

/**
 * Starts waiting children while fewer than `cap` run. Each count, pick and mark runs with no await in
 * between, so concurrent pumps never pass the cap. Returns when to look again (a start failed, or a
 * stale running slot frees later while children wait), or null.
 */
export const slotPump = async (sql: SqlStorage, env: Env, cap: number, now = Date.now()): Promise<number | null> => {
  sql.exec(`DELETE FROM cb_spawn_slot WHERE state = 'running' AND at < ?`, now - SLOT_STALE_MS)
  for (;;) {
    if (slotCounts(sql).running >= cap) break
    const next = sql.exec<{ child: string; start: string }>(`SELECT child, start FROM cb_spawn_slot WHERE state = 'waiting' ORDER BY at, child LIMIT 1`).toArray()[0]
    if (!next) return null
    sql.exec(`UPDATE cb_spawn_slot SET state = 'running', at = ? WHERE child = ?`, now, next.child)
    try {
      const r = await childStub(env, JSON.parse(next.start) as ChildStart).spawnStart(JSON.parse(next.start) as ChildStart)
      // A child that already ended (a repeated start) holds no slot.
      if (r.ended) sql.exec(`DELETE FROM cb_spawn_slot WHERE child = ?`, next.child)
    } catch (e) {
      console.warn(JSON.stringify({ msg: "chief_brain.spawn_start_failed", child: next.child, error: String(e).slice(0, 200) }))
      sql.exec(`UPDATE cb_spawn_slot SET state = 'waiting' WHERE child = ? AND state = 'running'`, next.child)
      return Date.now() + 5_000
    }
  }
  const oldest = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM cb_spawn_slot WHERE state = 'running'`).one().at
  return slotCounts(sql).waiting > 0 && oldest !== null ? Number(oldest) + SLOT_STALE_MS + 1_000 : null
}

// ------------------------------------------------------------------ parent brain: reports

/** Stores a child's report (first one wins); true when it was new. */
export const takeReport = (sql: SqlStorage, n: number, status: "done" | "failed", report: string, now: number): boolean =>
  sql.exec(`UPDATE cb_spawn SET state = ?, report = ?, ended = ? WHERE n = ? AND state IN ('queued', 'enqueued') RETURNING n`, status, report.slice(0, REPORT_MAX), now, n).toArray().length > 0

const clipBytes = (text: string, max: number): string => {
  const enc = new TextEncoder()
  if (enc.encode(text).length <= max) return text
  let out = [...text].slice(0, max)
  while (enc.encode(out.join("")).length > max - 4) out = out.slice(0, Math.floor(out.length * 0.9))
  return `${out.join("")} …`
}

type Pending = { n: number; name: string; conversation: string; kind: string; thread_root: string | null; state: string; report: string | null; parent_run: string }

/**
 * Posts every stored, unposted report as a `work` card (as the Chief, keyed per child) and queues it
 * as a woken inbox row. Returns the conversations that got rows, and whether to try again later.
 */
export const postReports = async (env: Env, sql: SqlStorage, transaction: (f: () => void) => void, principal: Principal, host: string): Promise<{ conversations: Set<string>; retry: boolean }> => {
  const rows = sql.exec<Pending>(`SELECT n, name, conversation, kind, thread_root, state, report, parent_run FROM cb_spawn WHERE posted = 0 AND state IN ('done', 'failed') ORDER BY ended, n`).toArray()
  const conversations = new Set<string>()
  let retry = false
  for (const r of rows) {
    const report = r.report?.trim() || "(no report)"
    const res = await postWork(env, principal, {
      conversation: r.conversation,
      key: `spawn-report:${principal.agent}:${childKey(r.conversation, r.n)}`,
      session: childRunId(r.n),
      host,
      status: r.state === "done" ? "done" : "failed",
      preview: clipBytes(`${r.name}: ${report}`, PREVIEW_BYTES),
      ...(r.thread_root ? { thread_root: r.thread_root } : {})
    }).catch((e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) }))
    if (!res.ok && res.code === "owner.unreachable") {
      retry = true
      continue
    }
    transaction(() => {
      sql.exec(`UPDATE cb_spawn SET posted = 1 WHERE n = ?`, r.n)
      if (!res.ok || res.seq === undefined) return void console.warn(JSON.stringify({ msg: "chief_brain.spawn_report_refused", n: r.n, code: res.ok ? "no_seq" : res.code }))
      const busy = sql.exec<{ name: string }>(`SELECT name FROM cb_spawn WHERE parent_run = ? AND conversation = ? AND state IN ('queued', 'enqueued') ORDER BY n`, r.parent_run, r.conversation).toArray().map((x) => x.name)
      const text = `[${r.name}] ${report}${r.state === "done" ? "" : " (the subagent failed)"}${busy.length > 0 ? `\n(still at work: ${busy.join(", ")})` : "\n(all subagents of this request have reported)"}`
      sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, woke) VALUES (?, ?, ?, ?, ?, ?, 1) ON CONFLICT (message) DO NOTHING`, res.message ?? `spawn:${r.n}`, r.conversation, res.seq, r.kind, r.thread_root, text)
      conversations.add(r.conversation)
    })
  }
  return { conversations, retry }
}

/**
 * The live "N subagents" line (the client adds the elapsed time from `since`): a pseudo-run
 * `subs_<first n>` per busy period of this conversation's children; ended (a terminal run change)
 * when the last child reports.
 */
export const subagentActivity = (env: Env, sql: SqlStorage, agent: string, conversation: string, now = Date.now()): Promise<void> => {
  const key = `subs.live:${conversation}`
  const busy = sql.exec<{ c: number; first: number | null }>(`SELECT COUNT(*) AS c, MIN(n) AS first FROM cb_spawn WHERE conversation = ? AND state IN ('queued', 'enqueued')`, conversation).one()
  const cur = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, key).toArray()[0]?.value
  const live = cur ? (JSON.parse(cur) as { id: string; since: number }) : null
  const count = Number(busy.c)
  if (count === 0) {
    if (!live) return Promise.resolve()
    sql.exec(`DELETE FROM cb_config WHERE name = ?`, key)
    const run = { id: live.id, conversation, author: agent, answers: [], status: "done", started_at: live.since, ended_at: now, step_count: 0, last_step_seq: 0, model: "", harness: "pi-durable", session: { kind: "pi", id: live.id, host: "cloud" } }
    return runChanged(env, conversation, agent, run, [])
  }
  const next = live ?? { id: `subs_${Number(busy.first)}`, since: now }
  if (!live) sql.exec(`INSERT INTO cb_config (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, key, JSON.stringify(next))
  return liveFrame(env, conversation, agent, { type: "run.activity", conversation, run: next.id, line: `${count} subagent${count === 1 ? "" : "s"}`, since: next.since, at: now })
}
