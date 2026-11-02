import { type LifecycleJobOutcome } from "agents/lifecycle"
import { chiefPrincipal } from "./brain-io.ts"
import { lastTalk, runError, type Run, type Step } from "./brain-runs.ts"
import { writeConfig } from "./brain-store.ts"
import { creditsCanStart } from "./models.ts"
import { clipReply, linkIds } from "./brain-text.ts"
import { type ChildStart, childInput, childObject, childRunId, postReports, readChild, slotCounts, slotEnqueue, slotPump, CHILD_LOST_MS, archiveAndDrop, childReportText, forwardOutcomes, outcomeWhere, keepMs, turnWhereOf, type AgentOutcome, checkOutcomes, noteAgentCall, postOutcomes, queueOutcome, spawnMax, subagentActivity, takeReport } from "./brain-spawn.ts"
import { openCloudWorkspace } from "./brain-spawn-workspace.ts"
import { handStub, listHands } from "../hand-api.ts"
import type { HandReply } from "../hand-wire.ts"
import { type ChiefBrainDO, POST_RETRY_MS, HOST, brainName, type Admission } from "./brain-do.ts"

/**
 * The subagent glue of a ChiefBrainDO (brain-do.ts; the data and pure parts are in brain-spawn.ts): the
 * settings object's child slots, the child role's start, admission, end, report and cleanup, the parent's
 * report intake and delivery, and agent turn outcomes. Functions over the object (b), split out of brain-do.ts.
 */

/** Parent brain: did it spawn child `n` (the runs route asks before it reaches a child object). */
export async function spawned(b: ChiefBrainDO, n: number): Promise<boolean> {
  return b.sql.exec(`SELECT 1 FROM cb_spawn WHERE n = ?`, n).toArray().length > 0
}

/** Parent brain: a deleted child's run record (its object's storage is gone), or null. */
export async function spawnRun(b: ChiefBrainDO, n: number, afterSeq = 0): Promise<{ run: Run; steps: Array<Step>; has_more: boolean } | null> {
  const body = b.sql.exec<{ body: string }>(`SELECT body FROM cb_spawn_run WHERE n = ?`, n).toArray()[0]?.body
  if (!body) return null
  const v = JSON.parse(body) as { run: Run; steps: Array<Step> }
  return { run: v.run, steps: v.steps.filter((s) => s.seq > afterSeq), has_more: false }
}

/** Parent brain: keeps a child's run record before the child deletes its storage. */
export async function spawnArchive(b: ChiefBrainDO, n: number, body: string): Promise<void> {
  b.sql.exec(`INSERT INTO cb_spawn_run (n, body) VALUES (?, ?) ON CONFLICT (n) DO NOTHING`, n, body)
}

export function spawnHost(b: ChiefBrainDO) {
  return {
    env: b.doEnv,
    sql: b.sql,
    transaction: (f: () => void) => b.doCtx.storage.transactionSync(f),
    turn: () => (b.turnId && b.turnConversation ? { run: b.turnId, conversation: b.turnConversation } : undefined),
    config: () => b.config(),
    isChild: () => b.childOf() !== null,
    effectsAuthorized: () => b.effectsAuthorized(),
    enqueue: (items: ReadonlyArray<ChildStart>) => b.settingsOf(items[0]!.agent).spawnEnqueue(items[0]!.agent, items[0]!.owner, [...items]) as Promise<{ running: number; waiting: number }>,
    workspace: async (name: string) => {
      const c = b.config()
      if (!c.agent || !c.owner) return { ok: false as const, reason: "no Chief" }
      const caller = { kind: "chief" as const, user: c.owner, agent: c.agent }
      return openCloudWorkspace(
        {
          list: async () => {
            const r = await listHands(b.doEnv, caller)
            return r.ok ? r.value : []
          },
          exec: async (hand, argv) => {
            const r = (await handStub(b.doEnv, hand).call(caller, "exec", { argv: [...argv], timeout_ms: 20_000 }, 35_000)) as HandReply<unknown>
            if (!r.ok) return { exitCode: 1, stdout: "", stderr: r.error.message }
            const v = r.value as { exit_code?: number; exitCode?: number; stdout?: string; stderr?: string }
            return { exitCode: v.exit_code ?? v.exitCode ?? 0, stdout: v.stdout ?? "", stderr: v.stderr ?? "" }
          }
        },
        name
      )
    },
    changed: (conversation: string) => {
      b.subsChanged(conversation)
      // The lost-child check runs even when no report ever comes.
      void b.schedule("spawn-post", "spawn-post", Date.now() + CHILD_LOST_MS + 60_000)
    }
  }
}

/** Settings object: queue children; at most CHIEF_SPAWN_MAX of this Chief's children run at once. */
export async function spawnEnqueue(b: ChiefBrainDO, agent: string, owner: string, items: Array<ChildStart>): Promise<{ running: number; waiting: number }> {
  await b.lifecycle.start()
  const cfg = b.config()
  if (cfg.agent !== agent || cfg.owner !== owner || items.some((s) => s.agent !== agent || s.owner !== owner)) throw new Error("spawn: another chief's settings")
  slotEnqueue(b.sql, items, Date.now())
  await b.pumpSlots()
  return slotCounts(b.sql)
}

/** Settings object: a child reported; its slot frees and the next waiting child starts. */
export async function spawnDone(b: ChiefBrainDO, child: string): Promise<void> {
  await b.lifecycle.start()
  b.sql.exec(`DELETE FROM cb_spawn_slot WHERE child = ?`, child)
  await b.pumpSlots()
}

export async function pumpSlots(b: ChiefBrainDO): Promise<void> {
  const at = await slotPump(b.sql, b.doEnv, spawnMax(b.doEnv))
  if (at !== null) await b.schedule("spawn-pump", "spawn-pump", at)
}

/** Child object: take the task (once) and run it. `ended`: this child already reported (a repeated start). */
export async function spawnStart(b: ChiefBrainDO, s: ChildStart): Promise<{ ended: boolean }> {
  const id = childRunId(s.n)
  if (!readChild(b.sql)) {
    // Before the lifecycle starts: the harness opens with the child's tools and prompt.
    b.doCtx.storage.transactionSync(() => {
      writeConfig(b.sql, { spawn: JSON.stringify(s), agent: s.agent, owner: s.owner, enabled: "1", model: s.model, effort: s.effort, display_name: s.display_name })
      b.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, effect_authorized, status, model, started, input) VALUES (?, ?, ?, 'spawn', NULL, 0, 1, 'running', ?, ?, ?) ON CONFLICT (id) DO NOTHING`, id, s.conversation, s.parent_run, s.model, Date.now(), JSON.stringify(childInput(s)))
    })
    b.child = undefined
  }
  await b.lifecycle.start()
  const post = b.sql.exec<{ post: string | null }>(`SELECT post FROM cb_turn WHERE id = ?`, id).toArray()[0]?.post ?? null
  b.kick()
  return { ended: post === "reported" || post === "refused" }
}

/** Child: the Chief is on, live, under its daily turns, and the team has credits for the child's model (no model call otherwise). */
export async function childAdmit(b: ChiefBrainDO, c: ChildStart): Promise<string | null> {
  const a = (await b.settingsOf(c.agent).admit(c.agent, c.owner, true).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))) as Admission
  if (!a.ok) return a.reason
  const credits = await creditsCanStart(b.doEnv, { ...b.config(), model: c.model })
  return credits === "ok" ? null : credits === "exhausted" ? "credits_exhausted" : "owner.unreachable"
}

/** Child: the run ended; its report (the last talk, or a short failure line with no internal detail) goes to the parent. */
export async function childEnd(b: ChiefBrainDO, id: string, ok: boolean, reason: string | null): Promise<void> {
  const why = String(reason ?? "")
  const talk = ok ? lastTalk(b.sql, id) : ""
  const report = childReportText(ok, talk, why)
  if (!ok) console.warn(JSON.stringify({ msg: "chief_brain.spawn_child_failed", run: id, reason: why.slice(0, 300), error: runError(b.sql, id)?.slice(0, 300) }))
  b.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, input = NULL, reply = ?, post = 'pending' WHERE id = ?`, ok ? "done" : "failed", reason, Date.now(), clipReply(linkIds(report)), id)
  b.announce(id, [])
  await b.postAndSchedule(id)
}

/** Child: hands the report to the parent brain and frees the slot; retried (job) until both answer. */
export async function childReport(b: ChiefBrainDO, id: string): Promise<number | null> {
  const c = b.childOf()
  const t = b.sql.exec<{ status: string; reply: string | null; post: string; post_tries: number }>(`SELECT status, reply, post, post_tries FROM cb_turn WHERE id = ?`, id).toArray()[0]
  if (!c || !t || t.post !== "pending") return null
  const parent = b.doEnv.CHIEF_BRAIN_DO.get(b.doEnv.CHIEF_BRAIN_DO.idFromName(brainName(c.agent, c.conversation)))
  try {
    await parent.spawnReport(c.n, t.status === "done" ? "done" : "failed", t.reply ?? "")
    await b.settingsOf(c.agent).spawnDone(childObject(c.agent, c.conversation, c.n))
    b.sql.exec(`UPDATE cb_turn SET post = 'reported' WHERE id = ?`, id)
    await b.schedule("spawn-gc", "spawn-gc", Date.now() + keepMs(b.doEnv))
    return null
  } catch (e) {
    console.warn(JSON.stringify({ msg: "chief_brain.spawn_report_retry", run: id, tries: t.post_tries, error: String(e).slice(0, 200) }))
    if (t.post_tries >= 30) {
      b.sql.exec(`UPDATE cb_turn SET post = 'refused' WHERE id = ?`, id)
      await b.settingsOf(c.agent).spawnDone(childObject(c.agent, c.conversation, c.n)).catch(() => undefined)
      return null
    }
    b.sql.exec(`UPDATE cb_turn SET post_tries = post_tries + 1 WHERE id = ?`, id)
    return Date.now() + Math.min(60_000, POST_RETRY_MS * 2 ** Math.min(t.post_tries, 5))
  }
}

/** Child: CHIEF_SPAWN_KEEP_DAYS after its report, the run record moves to the parent and this object's storage goes. */
export async function childGc(b: ChiefBrainDO): Promise<LifecycleJobOutcome | void> {
  const c = b.childOf()
  if (!c) return
  // An agent session this child started still lives (its token works): the storage stays until it ends.
  if (b.sql.exec(`SELECT 1 FROM sqlite_master WHERE name = 'cb_agenttok'`).toArray().length > 0 && b.sql.exec(`SELECT 1 FROM cb_agenttok WHERE live = 1 LIMIT 1`).toArray().length > 0) return { rescheduleAt: Date.now() + 86_400_000 }
  const parent = b.doEnv.CHIEF_BRAIN_DO.get(b.doEnv.CHIEF_BRAIN_DO.idFromName(brainName(c.agent, c.conversation)))
  if (!(await archiveAndDrop(b.sql, c, (body) => parent.spawnArchive(c.n, body)))) return { rescheduleAt: Date.now() + 60 * 60_000 }
  b.child = undefined
}

/** Where the running turn's replies go (its conversation, kind and thread). */
export function turnWhere(b: ChiefBrainDO) {
  return b.turnId ? turnWhereOf(b.sql, b.turnId) : null
}

/** An `agent` tool call returned: what it saw is noted, and outcomes held back for it are checked now. */
export function agentCallEnded(b: ChiefBrainDO, id: string, output: string): void {
  b.agentCalls.delete(id)
  const where = b.turnWhere()
  if (where) noteAgentCall(b.sql, output, where)
  b.doCtx.waitUntil(b.flushOutcomes())
}

/**
 * HandDO: an agent turn of a session this object started ended. Queued, then posted to the Chief as a work
 * message unless its own agent call already saw it; a child forwards it to its parent.
 */
export async function agentOutcome(b: ChiefBrainDO, o: AgentOutcome): Promise<{ ok: true }> {
  await b.lifecycle.start()
  const c = b.childOf()
  const where = outcomeWhere(b.sql, o.session)
  if (!where) return { ok: true }
  queueOutcome(b.sql, o, where, c ? `${c.name}'s agent` : "Your agent", false)
  b.doCtx.waitUntil(b.flushOutcomes())
  return { ok: true }
}

/** Checks queued outcomes once no agent call is in flight (a call older than 15 min no longer holds them). */
export async function flushOutcomes(b: ChiefBrainDO): Promise<void> {
  for (const [id, at] of b.agentCalls) if (Date.now() - at > 15 * 60_000) b.agentCalls.delete(id)
  if (b.agentCalls.size > 0) {
    // Held for a call in flight: looked at again when it returns, or when it is too old to hold them.
    if (b.sql.exec(`SELECT 1 FROM cb_agent_out WHERE posted = 0 LIMIT 1`).toArray().length > 0) await b.schedule("agent-out", "agent-out", Math.min(...b.agentCalls.values()) + 15 * 60_000 + 1_000)
    return
  }
  const fresh = checkOutcomes(b.sql)
  const c = b.childOf()
  if (!c) return void (fresh.length > 0 && (await b.deliverReports()))
  // A child: its parent posts it, in the thread of the spawning turn.
  const parent = b.doEnv.CHIEF_BRAIN_DO.get(b.doEnv.CHIEF_BRAIN_DO.idFromName(brainName(c.agent, c.conversation)))
  if (!(await forwardOutcomes(b.sql, (o) => parent.spawnAgentOutcome(c.n, o)))) await b.schedule("agent-out", "agent-out", Date.now() + POST_RETRY_MS)
}

/** Parent brain: a child's agent outcome (checked there), posted in the thread of the spawning turn. */
export async function spawnAgentOutcome(b: ChiefBrainDO, n: number, o: AgentOutcome): Promise<{ ok: true }> {
  await b.lifecycle.start()
  const r = b.sql.exec<{ name: string; conversation: string; kind: string; thread_root: string | null }>(`SELECT name, conversation, kind, thread_root FROM cb_spawn WHERE n = ?`, n).toArray()[0]
  if (!r) return { ok: true }
  queueOutcome(b.sql, o, r, `${r.name}'s agent`, true)
  b.doCtx.waitUntil(b.deliverReports())
  return { ok: true }
}

/** Parent brain: a child's report (stored before anything else), then posted and queued. */
export async function spawnReport(b: ChiefBrainDO, n: number, status: "done" | "failed", report: string): Promise<{ ok: true }> {
  await b.lifecycle.start()
  takeReport(b.sql, n, status, report, Date.now())
  b.doCtx.waitUntil(b.deliverReports())
  return { ok: true }
}

/** Parent brain: posts stored reports as work cards and queues them as woken messages (steered into a running turn, or a new turn). */
export function deliverReports(b: ChiefBrainDO): Promise<void> {
  // A child posts nothing itself: its reports and agent outcomes go to its parent.
  if (b.childOf()) return Promise.resolve()
  if (b.reporting) return ((b.reportAgain = true), b.reporting)
  b.reporting = (async () => {
    do {
      b.reportAgain = false
      const cfg = b.config()
      if (!cfg.agent || !cfg.owner) return
      // A child that never reported within CHILD_LOST_MS counts as failed.
      b.sql.exec(`UPDATE cb_spawn SET state = 'failed', report = 'I did not report in time.', ended = ? WHERE state IN ('queued', 'enqueued') AND created < ?`, Date.now(), Date.now() - CHILD_LOST_MS)
      const a = await b.admitted(cfg.agent, cfg.owner, false).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))
      if (!a.ok && a.reason === "owner.unreachable") return void (await b.schedule("spawn-post", "spawn-post", Date.now() + POST_RETRY_MS))
      // The Chief was turned off, archived or placed: its reports are not posted.
      if (!a.ok) b.sql.exec(`UPDATE cb_spawn SET posted = 1 WHERE posted = 0 AND state IN ('done', 'failed')`)
      if (!a.ok) b.sql.exec(`UPDATE cb_agent_out SET posted = 2 WHERE posted = 0 AND checked = 1`)
      const r = a.ok ? await postReports(b.doEnv, b.sql, (f) => b.doCtx.storage.transactionSync(f), chiefPrincipal(cfg.agent, cfg.owner), `${HOST}:${cfg.agent}`) : { conversations: new Set<string>(), retry: false }
      const o = a.ok ? await postOutcomes(b.doEnv, b.sql, (f) => b.doCtx.storage.transactionSync(f), chiefPrincipal(cfg.agent, cfg.owner), `${HOST}:${cfg.agent}`) : { conversations: new Set<string>(), retry: false }
      for (const c of o.conversations) r.conversations.add(c)
      r.retry ||= o.retry
      if (r.retry) await b.schedule("spawn-post", "spawn-post", Date.now() + POST_RETRY_MS)
      for (const c of r.conversations) if (b.turnLive && b.turnId && b.turnConversation === c) await b.steerQueued(c)
      if (r.conversations.size > 0) b.kick()
      for (const { c } of b.sql.exec<{ c: string }>(`SELECT DISTINCT conversation AS c FROM cb_spawn`).toArray()) b.subsChanged(c)
    } while (b.reportAgain)
  })().finally(() => (b.reporting = undefined))
  return b.reporting
}

/** The live "N subagents" line of `conversation` (sent in order). */
export function subsChanged(b: ChiefBrainDO, conversation: string): void {
  const agent = b.config().agent
  if (!agent) return
  b.subsChain = b.subsChain.then(() => subagentActivity(b.doEnv, b.sql, agent, conversation)).catch(() => undefined)
  b.doCtx.waitUntil(b.subsChain)
}
