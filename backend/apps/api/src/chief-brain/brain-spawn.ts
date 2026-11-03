import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { Env } from "../env.ts"
import type { Principal } from "@cmux/ownership"
import { liveFrame, postWork, runChanged } from "./brain-io.ts"
import type { BrainConfig } from "./brain-store.ts"
import { oneLine, replyTarget, SHARED_CHIEF } from "./brain-text.ts"
import { effectRefusal } from "./effect-policy.ts"
import { readRun, readSteps } from "./brain-runs.ts"
import { workspaceNote, type OpenedWorkspace } from "./brain-spawn-workspace.ts"

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
  // Any brain: the agent sessions its own agent tool calls saw (last event seq, whether the turn was done).
  `CREATE TABLE IF NOT EXISTS cb_agent_seen (session TEXT PRIMARY KEY, conversation TEXT NOT NULL, kind TEXT NOT NULL, thread_root TEXT, last_seq INTEGER NOT NULL, done INTEGER NOT NULL)`,
  // Any brain: agent turn outcomes from hands (HandDO.agentOutcome); checked = 1 once known unseen by the Chief's own call.
  `CREATE TABLE IF NOT EXISTS cb_agent_out (key TEXT PRIMARY KEY, session TEXT NOT NULL, seq INTEGER NOT NULL, conversation TEXT NOT NULL, kind TEXT NOT NULL, thread_root TEXT, label TEXT NOT NULL, body TEXT NOT NULL, checked INTEGER NOT NULL DEFAULT 0, posted INTEGER NOT NULL DEFAULT 0, at INTEGER NOT NULL)`,
  // Parent brain: a deleted child's run record (archiveOf), served by the runs route instead of the child.
  `CREATE TABLE IF NOT EXISTS cb_spawn_run (n INTEGER PRIMARY KEY, body TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS cb_spawn_slot (child TEXT PRIMARY KEY, state TEXT NOT NULL, at INTEGER NOT NULL, start TEXT NOT NULL, tries INTEGER NOT NULL DEFAULT 0)`
]

/** Tasks per spawn call. */
export const SPAWN_MAX_TASKS = 8
const TASK_MAX = 8_000
const BRIEF_MAX = 16_000
/** A report the parent reads (the view doc: messages up to 30,000 characters). */
const REPORT_MAX = 30_000
/** Work-card preview shown to members (home-core allows 4096 bytes). */
const PREVIEW_BYTES_SHOWN = 600
/** A child that has not reported after this long is failed in the parent (its "still at work" line ends). */
export const CHILD_LOST_MS = 60 * 60_000
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

/**
 * The kind a report's woken row is queued under. A report is the Chief's own card, so the turn it
 * starts in a shared Chief conversation answers on the main timeline without quoting it.
 */
const reportKind = (kind: string): string => (kind === SHARED_CHIEF ? "chief" : kind)

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
  effectsAuthorized(): boolean
  /** The settings object queues the children and starts as many as its cap allows. */
  enqueue(items: ReadonlyArray<ChildStart>): Promise<{ running: number; waiting: number }>
  /** The live "N subagents" line changed. */
  changed(conversation: string): void
  /** A cloud workspace on the Chief's VM for one child (a655); absent in a host without hands. */
  workspace?(name: string): Promise<OpenedWorkspace>
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
    if (!host.effectsAuthorized()) return effectRefusal()
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
    // One workspace per child started by this call (a replayed call has none queued, so none repeats).
    const fresh = new Set(items.map((i) => i.n))
    const links: Array<string> = []
    if (host.workspace) for (const r of rows) if (fresh.has(r.n)) links.push(`${r.name}: ${workspaceNote(await host.workspace(r.task.split("\n")[0]!.slice(0, 48)))}`)
    if (links.length > 0) note += ` Workspaces: ${links.join("; ")}. Link each one when you tell the person about it.`
    host.changed(turn.conversation)
    return text(`Started ${rows.length} subagent${rows.length === 1 ? "" : "s"}: ${rows.map((r) => r.name).join(", ")}.${note} Each report comes back to you as a work message "[Name] ..."; do not wait for them.`)
  }
})

// ------------------------------------------------------------------ settings object: slots

const childStub = (env: Env, s: ChildStart) =>
  env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(childObject(s.agent, s.conversation, s.n))) as unknown as { spawnStart(s: ChildStart): Promise<{ ended: boolean }> }
const parentStub = (env: Env, s: ChildStart) =>
  env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${s.agent}/${s.conversation}`)) as unknown as { spawnReport(n: number, status: "done" | "failed", report: string): Promise<unknown> }
/** Starts of one child before it is given up (a failed report goes to the parent). */
const START_TRIES = 5

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
  // Every free slot is taken first (no await between the count and the marks), then all starts go out at once.
  const free = Math.max(0, cap - slotCounts(sql).running)
  const picked = free === 0 ? [] : sql.exec<{ child: string; start: string; tries: number }>(`SELECT child, start, tries FROM cb_spawn_slot WHERE state = 'waiting' ORDER BY at, child LIMIT ?`, free).toArray()
  for (const p of picked) sql.exec(`UPDATE cb_spawn_slot SET state = 'running', at = ?, tries = tries + 1 WHERE child = ?`, now, p.child)
  const results = await Promise.all(
    picked.map(async (p) => {
      const s = JSON.parse(p.start) as ChildStart
      try {
        const r = await childStub(env, s).spawnStart(s)
        // A child that already ended (a repeated start) holds no slot.
        if (r.ended) sql.exec(`DELETE FROM cb_spawn_slot WHERE child = ?`, p.child)
        return r.ended ? "freed" : "ok"
      } catch (e) {
        console.warn(JSON.stringify({ msg: "chief_brain.spawn_start_failed", child: p.child, tries: p.tries + 1, error: String(e).slice(0, 200) }))
        if (p.tries + 1 >= START_TRIES) {
          // Given up: the parent gets a failed report (so its "still at work" list ends) and the slot frees.
          sql.exec(`DELETE FROM cb_spawn_slot WHERE child = ?`, p.child)
          await parentStub(env, s).spawnReport(s.n, "failed", "I could not start.").catch(() => undefined)
          return "freed"
        }
        // Behind the other waiting children, so one bad child never blocks the queue.
        sql.exec(`UPDATE cb_spawn_slot SET state = 'waiting', at = ? WHERE child = ? AND state = 'running'`, Date.now(), p.child)
        return "retry"
      }
    })
  )
  if (results.includes("retry")) return Date.now() + 5_000
  // A freed slot (a repeated or given-up start) may let a waiting child start now.
  if (results.includes("freed")) return slotPump(sql, env, cap)
  const oldest = sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM cb_spawn_slot WHERE state = 'running'`).one().at
  return slotCounts(sql).waiting > 0 && oldest !== null ? Number(oldest) + SLOT_STALE_MS + 1_000 : null
}

// ------------------------------------------------------------------ child cleanup

/** How long a child object keeps its storage after its report reached the parent (CHIEF_SPAWN_KEEP_DAYS, default 7). */
export const keepMs = (env: Env): number => {
  const d = Number(env.CHIEF_SPAWN_KEEP_DAYS ?? "7")
  return (Number.isFinite(d) && d >= 0 ? d : 7) * 86_400_000
}
/** The run record the parent keeps for a deleted child: the run, its first 20 and last 180 steps (the answer is last), long texts cut to 2 KB. */
export const archiveOf = (run: unknown, steps: ReadonlyArray<Record<string, unknown>>): string => {
  const cut = (v: unknown) => (typeof v === "string" && v.length > 2_048 ? `${v.slice(0, 2_048)} [cut]` : v)
  const cutInput = (v: unknown) => (JSON.stringify(v ?? null).length > 2_048 ? cut(JSON.stringify(v)) : v)
  const kept = steps.length <= 200 ? steps : [...steps.slice(0, 20), ...steps.slice(-180)]
  const slim = kept.map((st) => ({ ...st, ...(st.text === undefined ? {} : { text: cut(st.text) }), ...(st.tool ? { tool: { ...(st.tool as Record<string, unknown>), output: cut((st.tool as Record<string, unknown>).output), input: cutInput((st.tool as Record<string, unknown>).input) } } : {}) }))
  return JSON.stringify({ run, steps: slim })
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
    // The full report goes only to the Chief; members see a short preview in the Chief's own line or a DM,
    // and only the status in a channel or group (the Chief decides what of a report the room sees).
    const shown = oneLine(r.kind) ? clipBytes(`${r.name}: ${report}`, PREVIEW_BYTES_SHOWN) : `${r.name}: ${r.state === "done" ? "done" : "failed"}`
    const res = await postWork(env, principal, {
      conversation: r.conversation,
      key: `spawn-report:${principal.agent}:${childKey(r.conversation, r.n)}`,
      session: childRunId(r.n),
      host,
      status: r.state === "done" ? "done" : "failed",
      preview: shown,
      ...(r.thread_root ? { thread_root: r.thread_root } : {})
    }).catch((e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) }))
    if (!res.ok && res.code === "owner.unreachable") {
      retry = true
      continue
    }
    transaction(() => {
      sql.exec(`UPDATE cb_spawn SET posted = 1 WHERE n = ?`, r.n)
      // A refused card still reaches the Chief (the inbox row is what it reads).
      if (!res.ok) console.warn(JSON.stringify({ msg: "chief_brain.spawn_report_refused", n: r.n, code: res.code }))
      // The row's seq is the brain's read cursor, not the card's: a turn's ack (last_seq) never passes a person's message it has not read.
      const seq = Number(sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, r.conversation).toArray()[0]?.seq ?? 0)
      const busy = sql.exec<{ name: string }>(`SELECT name FROM cb_spawn WHERE parent_run = ? AND conversation = ? AND state IN ('queued', 'enqueued') ORDER BY n`, r.parent_run, r.conversation).toArray().map((x) => x.name)
      const text = `[${r.name}] ${report}${r.state === "done" ? "" : " (the subagent failed)"}${busy.length > 0 ? `\n(still at work: ${busy.join(", ")})` : "\n(all subagents of this request have reported)"}`
      sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, ?, ?, ?, 1, 1) ON CONFLICT (message) DO NOTHING`, (res.ok && res.message) || `spawn:${r.n}`, r.conversation, seq, reportKind(r.kind), r.thread_root, text)
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

// ------------------------------------------------------------------ late agent outcomes

/** An agent turn's outcome, as HandDO.agentOutcome sends it. */
export interface AgentOutcome {
  readonly hand: string
  readonly hand_name: string
  readonly session: string
  readonly seq: number
  readonly status: "done" | "failed"
  readonly stop_reason: string
  readonly text: string
  readonly tools: ReadonlyArray<string>
  readonly errors: ReadonlyArray<string>
}

/** After the Chief's own `agent` tool call returns: what it saw of the session (a later outcome it did not see is posted). */
export const noteAgentCall = (sql: SqlStorage, output: string, where: { conversation: string; kind: string; thread_root: string | null }): void => {
  let v: { session?: unknown; done?: unknown; last_seq?: unknown }
  try {
    v = JSON.parse(output) as typeof v
  } catch {
    return
  }
  if (typeof v.session !== "string" || !v.session) return
  const seq = typeof v.last_seq === "number" ? v.last_seq : 0
  sql.exec(
    `INSERT INTO cb_agent_seen (session, conversation, kind, thread_root, last_seq, done) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (session) DO UPDATE SET last_seq = MAX(last_seq, excluded.last_seq), done = CASE WHEN excluded.last_seq >= last_seq THEN excluded.done ELSE done END`,
    v.session, where.conversation, where.kind, where.thread_root, seq, v.done === true ? 1 : 0
  )
}

/** Queues an outcome (once per session and event seq) where `where` says it belongs. */
/** Most outcomes one agent session may post per hour (a hand that repeats turn frames cannot flood the Chief). */
const OUTCOMES_PER_HOUR = 20
export const queueOutcome = (sql: SqlStorage, o: AgentOutcome, where: { conversation: string; kind: string; thread_root: string | null }, label: string, checked: boolean, now = Date.now()): void => {
  if (Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_agent_out WHERE session = ? AND at > ?`, o.session, now - 3_600_000).one().n) >= OUTCOMES_PER_HOUR) return
  sql.exec(
    `INSERT INTO cb_agent_out (key, session, seq, conversation, kind, thread_root, label, body, checked, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (key) DO NOTHING`,
    `${o.session}:${o.seq}`, o.session, o.seq, where.conversation, where.kind, where.thread_root, label, JSON.stringify(o), checked ? 1 : 0, now
  )
}

/** Unchecked outcomes: the ones the Chief's own call already saw are dropped (posted = 2); the rest are returned and marked checked. */
export const checkOutcomes = (sql: SqlStorage): Array<{ key: string; outcome: AgentOutcome }> => {
  const out: Array<{ key: string; outcome: AgentOutcome }> = []
  for (const r of sql.exec<{ key: string; session: string; seq: number; body: string }>(`SELECT key, session, seq, body FROM cb_agent_out WHERE checked = 0 AND posted = 0 ORDER BY at`).toArray()) {
    const seen = sql.exec<{ last_seq: number; done: number }>(`SELECT last_seq, done FROM cb_agent_seen WHERE session = ?`, r.session).toArray()[0]
    if (seen && seen.done === 1 && seen.last_seq >= r.seq) {
      sql.exec(`UPDATE cb_agent_out SET posted = 2 WHERE key = ?`, r.key)
      continue
    }
    sql.exec(`UPDATE cb_agent_out SET checked = 1 WHERE key = ?`, r.key)
    out.push({ key: r.key, outcome: JSON.parse(r.body) as AgentOutcome })
  }
  return out
}

const outcomeText = (label: string, o: AgentOutcome): string =>
  `[${label} on ${o.hand_name}] agent turn ${o.status}${o.stop_reason ? ` (${o.stop_reason})` : ""}: ${o.text.trim() || "(no text)"}${o.tools.length ? `\nTools: ${o.tools.join("; ")}` : ""}${o.errors.length ? `\nErrors: ${o.errors.join("; ")}` : ""}\n(session ${o.session})`

/** Posts checked outcomes as work cards (preview policy as reports) and queues them as woken inbox rows. */
export const postOutcomes = async (env: Env, sql: SqlStorage, transaction: (f: () => void) => void, principal: Principal, host: string): Promise<{ conversations: Set<string>; retry: boolean }> => {
  const rows = sql.exec<{ key: string; conversation: string; kind: string; thread_root: string | null; label: string; body: string }>(`SELECT key, conversation, kind, thread_root, label, body FROM cb_agent_out WHERE checked = 1 AND posted = 0 ORDER BY at`).toArray()
  const conversations = new Set<string>()
  let retry = false
  for (const r of rows) {
    const o = JSON.parse(r.body) as AgentOutcome
    const text = outcomeText(r.label, o)
    const res = await postWork(env, principal, {
      conversation: r.conversation,
      key: `agent-outcome:${principal.agent}:${r.key}`.slice(0, 200),
      session: `agent_${o.session}`.slice(0, 200),
      host,
      status: o.status,
      preview: oneLine(r.kind) ? clipBytes(text, PREVIEW_BYTES_SHOWN) : `${r.label}: agent turn ${o.status}`,
      ...(r.thread_root ? { thread_root: r.thread_root } : {})
    }).catch((e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) }))
    if (!res.ok && res.code === "owner.unreachable") {
      retry = true
      continue
    }
    transaction(() => {
      sql.exec(`UPDATE cb_agent_out SET posted = 1 WHERE key = ?`, r.key)
      const seq = Number(sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, r.conversation).toArray()[0]?.seq ?? 0)
      sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, ?, ?, ?, 1, 1) ON CONFLICT (message) DO NOTHING`, (res.ok && res.message) || `agent:${r.key}`, r.conversation, seq, reportKind(r.kind), r.thread_root, text.slice(0, REPORT_MAX))
      conversations.add(r.conversation)
    })
  }
  return { conversations, retry }
}

// ------------------------------------------------------------------ child helpers (kept out of brain-do.ts)

/** A child's report: its last answer, or a short failure line with no internal detail. */
export const childReportText = (ok: boolean, talk: string, why: string): string =>
  ok
    ? talk && talk.replace(/[^A-Za-z_]/g, "").toUpperCase() !== "NO_REPLY" ? talk : "(no answer)"
    : /^(disabled|other_chief|chief_archived|chief_placed)$/.test(why)
      ? "I could not do the task: the Chief is off or archived."
      : /credits/i.test(why)
        ? "I could not do the task: this team is out of Cloud credits."
        : /daily_turn_limit|daily_cap/.test(why)
          ? "I could not do the task: the Chief reached today's limit."
          : "I could not finish the task (the model did not answer, or it ran too long)."

/** Where a turn's replies go (its conversation, kind and thread). */
export const turnWhereOf = (sql: SqlStorage, turn: string): { conversation: string; kind: string; thread_root: string | null } | null => {
  const t = sql.exec<{ conversation: string; m: string; k: string; r: string | null }>(`SELECT conversation, trigger_message AS m, trigger_kind AS k, trigger_thread_root AS r FROM cb_turn WHERE id = ?`, turn).toArray()[0]
  return t ? { conversation: t.conversation, kind: t.k, thread_root: turnThread(t.k, t.m, t.r) } : null
}

/**
 * Child cleanup: the run record goes to the parent (`keep`), then every table of the brain and of pi is
 * dropped; the lifecycle's own job tables (cf_*) stay, since it records this job's end. False: try later.
 */
export const archiveAndDrop = async (sql: SqlStorage, c: ChildStart, keep: (body: string) => Promise<unknown>): Promise<boolean> => {
  const id = childRunId(c.n)
  const run = readRun(sql, c.agent, id)
  try {
    if (run) await keep(archiveOf(run, readSteps(sql, id, 0, 5_000) as unknown as Array<Record<string, unknown>>))
  } catch {
    return false
  }
  console.log(JSON.stringify({ msg: "chief_brain.spawn_child_deleted", child: childObject(c.agent, c.conversation, c.n) }))
  for (const { name } of sql.exec<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'table'`).toArray()) if (!name.startsWith("cf_") && !name.startsWith("_cf") && !name.startsWith("sqlite_")) sql.exec(`DROP TABLE IF EXISTS "${name.replace(/"/g, '""')}"`)
  return true
}

/** Where an agent outcome belongs: the conversation and thread of the call that saw the session, else of the newest turn. */
export const outcomeWhere = (sql: SqlStorage, session: string): { conversation: string; kind: string; thread_root: string | null } | null => {
  const seen = sql.exec<{ conversation: string; kind: string; thread_root: string | null }>(`SELECT conversation, kind, thread_root FROM cb_agent_seen WHERE session = ?`, session).toArray()[0]
  if (seen) return seen
  const last = sql.exec<{ id: string }>(`SELECT id FROM cb_turn ORDER BY started DESC LIMIT 1`).toArray()[0]
  return last ? turnWhereOf(sql, last.id) : null
}

/** A child's checked outcomes to its parent; false when one did not go (try later). */
export const forwardOutcomes = async (sql: SqlStorage, send: (o: AgentOutcome) => Promise<unknown>): Promise<boolean> => {
  let ok = true
  for (const r of sql.exec<{ key: string; body: string }>(`SELECT key, body FROM cb_agent_out WHERE checked = 1 AND posted = 0`).toArray()) {
    if (await send(JSON.parse(r.body) as AgentOutcome).then(() => true, () => false)) sql.exec(`UPDATE cb_agent_out SET posted = 1 WHERE key = ?`, r.key)
    else ok = false
  }
  return ok
}
