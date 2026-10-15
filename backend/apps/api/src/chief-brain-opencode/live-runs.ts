import type { Env } from "../env.ts"
import { runChanged } from "../chief-brain/brain-io.ts"
import { type Run, type Step, readSteps, upsertStep } from "../chief-brain/brain-runs.ts"
import { type CpNote, type CpRun, decodeNote } from "./contract.ts"

/**
 * The run side of OpencodeBrainDO: Chief Protocol notifications (run/start, run/step, run/delta,
 * run/activity, run/end) become the trajectory wire (cb_turn/cb_step rows in the P tables, read by
 * the same readers) and `conversation-run-changed` frames. run/delta is coalesced into the talk step
 * every 40 ms (no storage write). A run id maps to its wake row: the conversation of every run frame
 * is the host's, never the brain's. The reads behind GET /v1/chiefs/<agent>/runs are here too.
 */
const DELTA_FLUSH_MS = 40

export interface Live {
  readonly run: string
  readonly conversation: string
  readonly done: Promise<CpNote | null>
  resolve(v: CpNote | null): void
  /** Pending talk/thought text per step id, flushed every 40 ms. */
  readonly pending: Map<string, string>
  readonly text: Map<string, string>
  timer?: ReturnType<typeof setTimeout>
}

export interface LiveRunsDeps {
  readonly env: Env
  readonly sql: SqlStorage
  tx<T>(fn: () => T): T
  waitUntil(p: Promise<unknown>): void
  get(name: string): string | undefined
  set(name: string, value: string): void
  wakeOf(run: string): { n: number; conversation: string; state: string } | undefined
}

export class LiveRuns {
  private readonly live = new Map<string, Live>()
  constructor(private readonly deps: LiveRunsDeps) {}

  /** Every live run learns its stream ended (the turn loop then asks the brain `status`). */
  endAll(): void {
    for (const l of this.live.values()) l.resolve(null)
  }

  track(run: string, conversation: string): Live {
    let resolve!: (v: CpNote | null) => void
    const done = new Promise<CpNote | null>((r) => (resolve = r))
    const live: Live = { run, conversation, done, resolve, pending: new Map(), text: new Map() }
    this.live.set(run, live)
    return live
  }
  untrack(run: string): void {
    const l = this.live.get(run)
    if (l?.timer) clearTimeout(l.timer)
    this.live.delete(run)
  }

  onNote(raw: unknown): void {
    const decoded = decodeNote(raw)
    if (decoded._tag === "None") return
    const note = decoded.value
    const agent = this.deps.get("agent")
    if (!agent) return
    const runId = note.method === "run/start" || note.method === "run/end" ? note.params.run.id : note.params.run
    // The run's conversation is the wake's: a brain cannot write a run into another conversation.
    const wake = this.deps.wakeOf(runId)
    if (!wake) return
    const live = this.live.get(runId)
    switch (note.method) {
      case "run/start":
      case "run/end": {
        const r = { ...note.params.run, conversation: wake.conversation } as CpRun & Record<string, unknown>
        const ended = note.method === "run/end"
        const answers = Array.isArray(r.answers) ? (r.answers as Array<unknown>).filter((x): x is string => typeof x === "string").slice(0, 100) : []
        this.deps.tx(() => {
          this.deps.sql.exec(
            `INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, status, model, started, reason, ended, post) VALUES (?, ?, ?, 'chief', ?, 0, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (id) DO UPDATE SET status = excluded.status, reason = excluded.reason, ended = excluded.ended, post = excluded.post`,
            r.id, wake.conversation, answers.at(-1) ?? "", typeof r.thread_root === "string" ? r.thread_root : null, r.status, r.model ?? "claude-opus-5-5", r.started_at, r.error ?? null, r.ended_at ?? null, ended ? (r.status === "done" ? "posted" : "none") : null
          )
          for (const m of answers) this.deps.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, text, state, turn) VALUES (?, ?, 0, 'chief', '', 'done', ?) ON CONFLICT (message) DO UPDATE SET turn = excluded.turn`, m, wake.conversation, r.id)
          this.deps.sql.exec(`INSERT INTO oc_run (id, body) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET body = excluded.body`, r.id, JSON.stringify(r))
          if (ended) this.deps.sql.exec(`DELETE FROM oc_config WHERE name = ?`, `activity:${r.id}`)
        })
        if (live) this.flush(live)
        this.announce(agent, r.id, [])
        if (ended) live?.resolve(note)
        return
      }
      case "run/step": {
        const s = note.params.step
        const step = upsertStep(this.deps.sql, runId, s as never, Date.now())
        if (live && (s.kind === "talk" || s.kind === "thought")) {
          live.pending.delete(s.id)
          live.text.delete(s.id)
        }
        this.announce(agent, runId, [step])
        return
      }
      case "run/delta": {
        if (!live) return
        const p = note.params
        live.text.set(p.step, (live.text.get(p.step) ?? "") + p.text)
        live.pending.set(p.step, p.kind)
        if (!live.timer) live.timer = setTimeout(() => this.flush(live), DELTA_FLUSH_MS)
        return
      }
      case "run/activity":
        // Ephemeral: no frame for it on ConversationDO yet (the stream frame lands with hq-ec); kept for the run read while it runs.
        this.deps.set(`activity:${runId}`, note.params.line.slice(0, 80))
        return
    }
  }

  /** Partial talk/thought text as a step (no storage write): the page streams it until the full step lands. */
  private flush(live: Live): void {
    if (live.timer) clearTimeout(live.timer)
    live.timer = undefined
    const agent = this.deps.get("agent")
    if (!agent || live.pending.size === 0) return
    const now = Date.now()
    const steps = [...live.pending].map(([id, kind]) => ({ id, seq: 0, at: now, kind: kind === "thought" ? "thought" : "talk", text: live.text.get(id) ?? "" }) as Step)
    live.pending.clear()
    this.announce(agent, live.run, steps)
  }

  private announce(agent: string, runId: string, steps: ReadonlyArray<Step>): void {
    const run = this.readRun(agent, runId)
    if (run) this.deps.waitUntil(runChanged(this.deps.env, run.conversation, agent, run, steps))
  }

  private readRun(agent: string, id: string): (Run & Record<string, unknown>) | null {
    const body = this.deps.sql.exec<{ body: string }>(`SELECT body FROM oc_run WHERE id = ?`, id).toArray()[0]?.body
    if (!body) return null
    const r = JSON.parse(body) as Record<string, unknown>
    const counts = this.deps.sql.exec<{ n: number; last: number | null }>(`SELECT COUNT(*) AS n, MAX(seq) AS last FROM cb_step WHERE turn = ?`, id).one()
    const activity = this.deps.get(`activity:${id}`)
    return { ...r, author: agent, turn: `${agent}:chief-reply:${id}`, step_count: Number(counts.n), last_step_seq: Number(counts.last ?? 0), ...(activity && r.status === "running" ? { activity } : {}) } as Run & Record<string, unknown>
  }

  // Reads (the Worker checked membership).
  runs(conversation: string, before: number | undefined, limit: number): { runs: Array<Record<string, unknown>>; has_more: boolean } {
    const agent = this.deps.get("agent")
    if (!agent) return { runs: [], has_more: false }
    const rows = this.deps.sql.exec<{ id: string }>(`SELECT id FROM cb_turn WHERE conversation = ? AND started < ? ORDER BY started DESC LIMIT ?`, conversation, before ?? Number.MAX_SAFE_INTEGER, limit + 1).toArray()
    return { runs: rows.slice(0, limit).flatMap((r) => this.readRun(agent, String(r.id)) ?? []), has_more: rows.length > limit }
  }
  run(id: string, afterSeq = 0, limit = 500): { run: Record<string, unknown>; steps: Array<Step>; has_more: boolean } | null {
    const agent = this.deps.get("agent")
    const run = agent ? this.readRun(agent, id) : null
    if (!run) return null
    const steps = readSteps(this.deps.sql, id, afterSeq, limit + 1)
    return { run, steps: steps.slice(0, limit), has_more: steps.length > limit }
  }
}
