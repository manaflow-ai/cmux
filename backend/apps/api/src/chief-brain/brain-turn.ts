import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context"
import { ackWake, chiefPrincipal, postReply, readConversation, typing } from "./brain-io.ts"
import { flushMarks, lastTalk, markPending, runError, type Run, type Step, upsertStep } from "./brain-runs.ts"
import { writeConfig } from "./brain-store.ts"
import { marksHeader, ttlMs, turnPlan } from "./cache-prefix.ts"
import { AUTH_FAILED, claudeAuthFor } from "./claude-auth.ts"
import { prunePiEntries } from "./pi-prune.ts"
import { RETRY_MS } from "./memory.ts"
import { creditsCanStart, creditsNotice, turnFailedNotice, isClaude, isMetered, liveOf, pickTurnModel } from "./models.ts"
import { clipReply, formatMessage, inboxKind, isNoReply, linkIds, replyTarget } from "./brain-text.ts"
import { turnThread } from "./brain-spawn.ts"
import { ccRoute } from "../chief-brain-cc/vm.ts"
import { ccTurn } from "../chief-brain-cc/turn.ts"
import { OPUS } from "../model-gateway/routes.ts"
import { messageEffectAuthorized } from "./effect-policy.ts"
import { type ChiefBrainDO, POST_RETRY_MS, retryPost, HOST, msOr, SETTLE_MS, TURN_MS, handsContinueText, type Admission } from "./brain-do.ts"

/**
 * The turn loop of a ChiefBrainDO (brain-do.ts): a wake queues messages, the drain admits and opens one
 * turn per batch, a turn runs on pi (messages that arrive meanwhile are steered in), and its reply is
 * posted as the Chief, then the wake cursor moves. Functions over the object (b), split out of brain-do.ts.
 */

/** MuxDO forwards a committed wake here. Pulls the conversation's new messages as the chief and starts a turn. */
export async function wake(b: ChiefBrainDO, w: { agent: string; owner: string; conversation: string; seq: number; reason: string; at?: number }): Promise<{ queued: number } | { skipped: string }> {
  markPending(b.sql, "wake")
  // When MuxDO committed the wake (the conversation's outbox delivered it): Run.timing mux_at.
  if (typeof w.at === "number" && Date.now() - w.at < 60_000) markPending(b.sql, "mux", Math.min(w.at, Date.now()))
  // A cold object: when it was made (its constructor; wasm and memory load) and when its lifecycle was ready.
  // Only when this wake made the object (another entry point that made it long ago is not a cold wake).
  if (b.bootAt !== undefined) [Date.now() - b.bootAt < 10_000 && markPending(b.sql, "boot", b.bootAt), (b.bootAt = undefined)]
  await b.lifecycle.start()
  markPending(b.sql, "life")
  // The admission and the conversation read go at the same time (the read changes nothing; a refusal ignores it).
  const reading = readConversation(b.doEnv, w.conversation, chiefPrincipal(w.agent, w.owner))
  reading.catch(() => undefined)
  const a = await b.admitted(w.agent, w.owner, false)
  if (!a.ok) return skip(b, w, a.reason)
  // While the wake reads the conversation and the turn is admitted: the owner's turns object, the route's auth and the team's meter warm up.
  // (Not on the Claude Code route, chief-brain-cc/: its turns use none of them.)
  if (!ccRoute(b.doEnv, w.owner)) {
    if (isMetered(a.config.model)) b.doCtx.waitUntil(b.turns(w.owner).warm().catch(() => undefined))
    if (isClaude(a.config.model)) b.doCtx.waitUntil(claudeAuthFor(b.doEnv, b.holder).catch(() => undefined))
    b.doCtx.waitUntil(b.harness.pi().catch(() => undefined))
    b.doCtx.waitUntil(creditsCanStart(b.doEnv, a.config).catch(() => undefined))
  }
  const view = await reading
  if ("refused" in view) return skip(b, w, view.refused)
  // A conversation this brain never read starts at the wake: older history is not answered.
  const cursor = b.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq ?? w.seq - 1
  let queued = 0
  let top = cursor
  // On the Claude Code route each attachment line names its file in the turn machine (chief-brain-cc/attachments.ts writes it there).
  const files = ccRoute(b.doEnv, w.owner)
  for (const m of view.messages) {
    if (m.seq <= cursor) continue
    top = Math.max(top, m.seq)
    if (m.author === w.agent || m.retracted_at !== undefined) continue
    const text = formatMessage(view.head, m, { files, owner: w.owner })
    if (!text) continue
    const fresh = b.sql
      .exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (message) DO NOTHING RETURNING n`, m.id, w.conversation, m.seq, inboxKind(view.head), m.thread_root ?? null, text, messageEffectAuthorized(view.head, m, view.messages, w.owner, w.agent) ? 1 : 0)
      .toArray()
    queued += fresh.length
  }
  // The woken message (it may have come in as context with an earlier wake).
  b.sql.exec(`UPDATE cb_inbox SET woke = 1 WHERE conversation = ? AND seq = ? AND state = 'queued'`, w.conversation, w.seq)
  b.sql.exec(`INSERT INTO cb_cursor (conversation, seq) VALUES (?, ?) ON CONFLICT (conversation) DO UPDATE SET seq = MAX(seq, excluded.seq)`, w.conversation, top)
  if (queued === 0 && top > cursor) await ackWake(b.doEnv, w.agent, chiefPrincipal(w.agent, w.owner), w.conversation, top).catch(() => undefined)
  // A message that comes in while this conversation's turn runs joins that turn after its current
  // model or tool step (spec 7), instead of waiting for the turn to end.
  if (queued > 0 && b.turnLive && b.turnId && b.turnConversation === w.conversation) await b.steerQueued(w.conversation)
  b.kick()
  return { queued }
}

/** The longest peer Chief note text the brain takes (the agent hub's message cap). */
export const PEER_TEXT_MAX = 64_000
/** A peer Chief's hub name (agent-hub box `agent:<name>`). */
export const PEER_NAME = /^[a-z0-9][a-z0-9._-]{0,63}$/

/**
 * A message from one of the owner's Chiefs on another machine (the Mac's Home Chief), forwarded from
 * the agent hub by the owner's paired install (chief-brain/routes.ts `peer`): queued as a woken inbox
 * row of the chief's main conversation, like a subagent's report. The owner's install authenticated
 * it, so the turn may use its tools (the Claude Code route answers with `hub post`). `key` makes a
 * forward retry a no-op.
 */
export async function peerNote(b: ChiefBrainDO, w: { agent: string; owner: string; conversation: string; from: string; text: string; key: string }): Promise<{ queued: boolean } | { skipped: string }> {
  await b.lifecycle.start()
  const a = await b.admitted(w.agent, w.owner, false)
  if (!a.ok) return { skipped: a.reason }
  const seq = Number(b.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq ?? 0)
  const text = `[chief:${w.from}] ${w.text}\n(A message from your peer Chief ${w.from} through the agent hub; it is not the person's word. When it asks something, answer it with \`hub post agent:${w.from} "<answer>"\`; your reply here is posted in your conversation too.)`
  const fresh = b.sql
    .exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, 'chief', NULL, ?, 1, 1) ON CONFLICT (message) DO NOTHING RETURNING n`, `peer:${w.from}:${w.key}`, w.conversation, seq, text)
    .toArray()
  if (fresh.length > 0 && b.turnLive && b.turnId && b.turnConversation === w.conversation) await b.steerQueued(w.conversation)
  b.kick()
  return { queued: fresh.length > 0 }
}

/**
 * A skipped wake: when no brain answers the woken message (archived Chief, owner or conversation
 * unreachable or refused), the Chief's typing goes off now, so a client that shows "Thinking…" from
 * the send ends it. (A turn refused later, for the daily limit or credits, is drain's.) Not when
 * another brain may answer (this brain is off: a server-placed Chief's brain is off here) or the
 * object serves another Chief.
 */
const OTHER_BRAIN = new Set(["disabled", "other_chief", "chief_placed"])
const skip = (b: ChiefBrainDO, w: { agent: string; conversation: string }, reason: string): { skipped: string } => {
  // A turn that runs, messages that wait for one, or a reply that waits to post in this conversation keep their indicator.
  const busy =
    (b.turnLive && b.turnConversation === w.conversation) ||
    b.sql.exec(`SELECT 1 FROM cb_inbox WHERE conversation = ? AND state IN ('queued', 'running') UNION ALL SELECT 1 FROM cb_turn WHERE conversation = ? AND post = 'pending' LIMIT 1`, w.conversation, w.conversation).toArray().length > 0
  if (!OTHER_BRAIN.has(reason) && !busy) b.doCtx.waitUntil(typing(b.doEnv, w.conversation, w.agent, false))
  return { skipped: reason }
}

/**
 * Logs the conversation's queued messages of the turn's thread into the running turn and gives them
 * to it (pi steer, after its current step). The op is recorded (memory and storage) before anything
 * awaits, so the turn's wait loop and a restart both see it; a failed steer puts the rows back.
 */
export async function steerQueued(b: ChiefBrainDO, conversation: string): Promise<void> {
  const turn = b.turnId
  if (!turn || !b.turnLive) return
  const t = b.sql.exec<{ m: string; k: string; r: string | null }>(`SELECT trigger_message AS m, trigger_kind AS k, trigger_thread_root AS r FROM cb_turn WHERE id = ?`, turn).toArray()[0]
  const root = t?.r ?? null
  // Only the turn's own thread joins it (its reply goes there; a subagent report names that thread); other threads wait for their own turn.
  const rows = b.sql.exec<{ n: number; message: string; seq: number; text: string; effect_authorized: number }>(`SELECT n, message, seq, text, effect_authorized FROM cb_inbox WHERE state = 'queued' AND conversation = ? AND (thread_root IS ? OR thread_root IS ?) ORDER BY n`, conversation, root, t ? turnThread(t.k, t.m, root) : root).toArray()
  if (rows.length === 0) return
  const op = `${turn}:steer:${rows[0]!.n}`
  const text = rows.map((r) => r.text).join("\n\n")
  const before = b.sql.exec<{ s: number }>(`SELECT last_seq AS s FROM cb_turn WHERE id = ?`, turn).one().s
  b.doCtx.storage.transactionSync(() => {
    for (const r of rows) {
      b.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, `user:${r.message}`)
      b.memory.append("user", r.text)
      b.sql.exec(`UPDATE cb_inbox SET state = 'running', turn = ? WHERE n = ?`, turn, r.n)
    }
    if (rows.some((r) => r.effect_authorized !== 1)) b.sql.exec(`UPDATE cb_turn SET effect_authorized = 0 WHERE id = ?`, turn)
    b.sql.exec(`UPDATE cb_turn SET last_seq = MAX(last_seq, ?) WHERE id = ?`, Math.max(...rows.map((r) => r.seq)), turn)
    writeConfig(b.sql, { [`steer:${turn}`]: JSON.stringify([...b.steerOps(turn), { op, text }]) })
  })
  b.steered.push(op)
  b.compactor.pump()
  try {
    await b.harness.session().steer([{ type: "text" as const, text }], { operationId: op })
  } catch (e) {
    console.warn(JSON.stringify({ msg: "chief_brain.steer_failed", run: turn, error: String(e).slice(0, 200) }))
    // Not given to pi: the rows wait for the next turn, and the turn's ack range is as before.
    b.steered = b.steered.filter((x) => x !== op)
    writeConfig(b.sql, { [`steer:${turn}`]: JSON.stringify(b.steerOps(turn).filter((x) => x.op !== op)) })
    b.sql.exec(`UPDATE cb_inbox SET state = 'queued', turn = NULL WHERE turn = ? AND n >= ? AND n <= ?`, turn, rows[0]!.n, rows[rows.length - 1]!.n)
    b.sql.exec(`UPDATE cb_turn SET last_seq = ? WHERE id = ?`, before, turn)
  }
}

/** The joined operations of `turn`, as stored (restart: the turn waits for them and gives pi any it never got). */
export function steerOps(b: ChiefBrainDO, turn: string): Array<{ op: string; text: string }> {
  const v = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `steer:${turn}`).toArray()[0]?.value
  return v ? (JSON.parse(v) as Array<{ op: string; text: string }>) : []
}

export function kick(b: ChiefBrainDO): void {
  if (b.draining) return
  let failed = false
  b.draining = b.drain()
    .catch((e: unknown) => void (failed = true, console.error(JSON.stringify({ msg: "chief_brain.drain_failed", error: String(e).slice(0, 300) }))))
    .finally(() => {
      b.draining = undefined
      // A wake that queued rows while the drain was ending saw it still running: look again (after a failure, later).
      if (b.sql.exec(`SELECT 1 FROM cb_inbox WHERE state = 'queued' AND woke = 1 LIMIT 1`).toArray().length === 0) return
      if (failed) void b.schedule("drain", "drain", Date.now() + RETRY_MS)
      else b.kick()
    })
  b.doCtx.waitUntil(b.draining)
}

export async function drain(b: ChiefBrainDO): Promise<void> {
  const child = b.childOf()
  if (child) {
    const r = b.sql.exec<{ id: string; submitted: number }>(`SELECT id, submitted FROM cb_turn WHERE status = 'running' LIMIT 1`).toArray()[0]
    if (!r) return
    // Admitted once (a daily turn counted once, also across an eviction); an unreachable owner retries later.
    if (!r.submitted && !b.sql.exec(`SELECT 1 FROM cb_config WHERE name = 'spawn.admitted'`).toArray().length) {
      const refused = await b.childAdmit(child)
      if (refused === "owner.unreachable") return void (await b.schedule("drain", "drain", Date.now() + RETRY_MS))
      if (refused) return b.childEnd(r.id, false, refused)
      writeConfig(b.sql, { "spawn.admitted": "1" })
    }
    return b.runTurn(r.id)
  }
  for (;;) {
    const running = b.sql.exec<{ turn: string }>(`SELECT turn FROM cb_inbox WHERE state = 'running' ORDER BY n LIMIT 1`).toArray()[0]
    if (running) {
      await b.runTurn(running.turn)
      continue
    }
    // Only a woken message starts a turn; the messages before it ride along as context.
    const woken = b.sql.exec<{ conversation: string }>(`SELECT conversation FROM cb_inbox WHERE state = 'queued' AND woke = 1 ORDER BY n LIMIT 1`).toArray()[0]
    if (!woken) return
    const cfg = b.config()
    const a = cfg.agent && cfg.owner ? await b.admitted(cfg.agent, cfg.owner, true).catch((): Admission => ({ ok: false, reason: "owner.unreachable" })) : ({ ok: false, reason: "unbound" } as Admission)
    const rows = b.sql
      .exec<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string; woke: number; effect_authorized: number }>(`SELECT n, message, seq, kind, thread_root, text, woke, effect_authorized FROM cb_inbox WHERE state = 'queued' AND conversation = ? ORDER BY n`, woken.conversation)
      .toArray()
    if (!a.ok && a.reason === "owner.unreachable") return void (await b.schedule("drain", "drain", Date.now() + RETRY_MS))
    if (!a.ok) {
      // Not answered (off, archived, placed, over the limit): the wakes are acked so the queue stays bounded.
      b.sql.exec(`UPDATE cb_inbox SET state = 'skipped' WHERE state = 'queued' AND conversation = ?`, woken.conversation)
      console.warn(JSON.stringify({ msg: "chief_brain.turn_refused", reason: a.reason }))
      // The notice may post nothing (one per hour, or it failed): the typing goes off either way.
      if (a.reason === "credits_exhausted") await creditsNotice(b.doEnv, cfg, woken.conversation)
      if (cfg.agent && !OTHER_BRAIN.has(a.reason)) await typing(b.doEnv, woken.conversation, cfg.agent, false)
      if (cfg.agent && cfg.owner && rows.length > 0) await ackWake(b.doEnv, cfg.agent, chiefPrincipal(cfg.agent, cfg.owner), woken.conversation, Math.max(...rows.map((r) => r.seq))).catch(() => undefined)
      continue
    }
    // The reference client's Memory.settle(mem, from): every message before the new ones summarized, so the
    // view shows them all as lines and the input holds only the new messages; bounded (SETTLE_MS), after
    // which the turn runs on the last rendered view plus the unsummarized messages whole.
    // A failing or rate-limited compactor costs no wait (the turn goes at once on the last view plus the whole messages).
    markPending(b.sql, "admitted")
    const healthy = !b.compactor.off() && b.compactor.failures().length === 0 && b.compactor.cooling() === 0
    const settleMs = msOr(b.doEnv.CHIEF_BRAIN_SETTLE_MS, SETTLE_MS)
    const fresh = healthy && settleMs > 0 ? await b.compactor.settleTo(b.memory.len(), AbortSignal.timeout(settleMs)) : b.memory.first() >= b.memory.len()
    markPending(b.sql, "settled")
    // Messages that came during the wait ride along (the same conversation's queue, read again).
    const all = b.sql
      .exec<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string; woke: number; effect_authorized: number }>(`SELECT n, message, seq, kind, thread_root, text, woke, effect_authorized FROM cb_inbox WHERE state = 'queued' AND conversation = ? ORDER BY n`, woken.conversation)
      .toArray()
    if (!fresh) console.warn(JSON.stringify({ msg: "chief_brain.settle_timeout", first: b.memory.first(), len: b.memory.len(), failures: b.compactor.failures().length }))
    if (all.length > 0) b.openTurn(woken.conversation, all, fresh)
  }
}

/**
 * Logs the new messages, then builds the input (Memory.turnInput: a fresh view and the new messages, or the last view
 * plus the unsummarized messages) and its cache marks (cache-prefix.ts) with the turn row in one transaction (a restart
 * resubmits the same bytes).
 */
export function openTurn(b: ChiefBrainDO, conversation: string, rows: ReadonlyArray<{ n: number; message: string; seq: number; kind: string; thread_root: string | null; text: string; woke: number; effect_authorized: number }>, fresh = false): void {
  const id = `run_${rows[0]!.n}`
  let input = "[]"
  const trigger = [...rows].reverse().find((r) => r.woke === 1) ?? rows[rows.length - 1]!
  b.doCtx.storage.transactionSync(() => {
    for (const r of rows) {
      b.sql.exec(`INSERT INTO oc_logged (key) VALUES (?) ON CONFLICT DO NOTHING`, `user:${r.message}`)
      b.memory.append("user", r.text)
      b.sql.exec(`UPDATE cb_inbox SET state = 'running', turn = ? WHERE n = ?`, id, r.n)
    }
    // pi-ai drops a whitespace-only text block, which would shift the mark indices.
    const blocks = b.memory.turnInput(rows.length, fresh).filter((t) => t.trim().length > 0)
    input = JSON.stringify(blocks)
    // Where this turn's first request reads (an earlier turn's entry) and writes (the view's last whole block).
    writeConfig(b.sql, { [`marks:${id}`]: marksHeader(turnPlan(b.sql, b.config().model, blocks, ttlMs(b.doEnv.CHIEF_BRAIN_CACHE_TTL))) })
    b.sql.exec(
      `INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, trigger_thread_root, last_seq, effect_authorized, status, model, started, input) VALUES (?, ?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)`,
      id, conversation, trigger.message, trigger.kind, trigger.thread_root, Math.max(...rows.map((r) => r.seq)), rows.every((r) => r.effect_authorized === 1) ? 1 : 0, b.config().model, Date.now(), input
    )
  })
  b.compactor.pump()
  b.announce(id, (flushMarks(b.sql, id), []))
}

export async function runTurn(b: ChiefBrainDO, id: string): Promise<void> {
  const row = b.sql.exec<{ submitted: number; input: string | null; model: string; conversation: string }>(`SELECT submitted, input, model, conversation FROM cb_turn WHERE id = ?`, id).toArray()[0]
  if (!row) throw new Error(`run ${id} has no row`)
  const agent = b.config().agent
  b.turnId = id
  b.turnConversation = row.conversation
  const child = b.childOf()
  if (agent && !child) void typing(b.doEnv, row.conversation, agent, true)
  let ok = false
  let reason: string | null = null
  let timer: ReturnType<typeof setTimeout> | undefined
  // The Claude Code route (chief-brain-cc/): the turn runs as Claude Code in its own VM; everything else here is the same.
  // Claude Code creates a VM and runs with bypass permissions. A participant-authored turn must
  // stay on the Pi path, where effectful tools return an owner-approval request.
  const cc = !child && b.effectsAuthorized() && ccRoute(b.doEnv, b.config().owner)
  try {
    if (cc) {
      const model = isClaude(row.model) ? row.model : OPUS
      if (model !== row.model) b.sql.exec(`UPDATE cb_turn SET model = ? WHERE id = ?`, model, id)
      // The owner's daily paid-turn cap counts these turns too (once, at the first start).
      if (!row.submitted) {
        const owner = b.config().owner ?? ""
        const counted = await b.turns(owner).claudeTurn(owner, model).catch(() => "holder_unreachable")
        if (counted !== "ok") throw new Error(`paid model refused (${counted})`)
      }
      const r = await ccTurn(b, id, JSON.parse(row.input ?? "[]") as Array<string>, model, row.submitted === 1)
      ok = r.ok
      reason = r.reason
    } else {
      if (!row.submitted) {
        const blocks = JSON.parse(row.input ?? "[]") as Array<string>
        // A paid model: an allowed owner, the route serves it, under the deployment's cap, with the route's sign-in; else the fallback, which passes the same gate when it is paid; else no turn.
        const owner = b.config().owner ?? ""
        // Step marks (Run.timing *_at): the paid-turn count, the route's auth, pi open; the count and pi open run at the same time.
        const mark = (m: string) => void b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, id, m, Date.now())
        // Only pi itself opens beside the check; its root context is made once the model is known.
        const piOpen = b.harness.pi()
        piOpen.catch(() => undefined)
        const picked = await pickTurnModel(row.model, b.doEnv.CHIEF_BRAIN_FALLBACK_MODEL, (m) => b.turns(owner).claudeTurn(owner, m).then((v) => (mark("count"), v !== "ok" || !isClaude(m) ? v : claudeAuthFor(b.doEnv, b.holder).then(() => (mark("auth"), "ok"), () => "auth_failed"))).catch(() => "holder_unreachable"))
        mark("paid")
        if (picked.reason) console.warn(picked.reason.includes("auth_failed") ? AUTH_FAILED : JSON.stringify({ msg: "chief_brain.paid_model_refused", reason: picked.reason }))
        if (picked.model === null || picked.model !== row.model) [b.announce(id, [upsertStep(b.sql, id, { id: "note:model", kind: "note", text: picked.model === null ? `No model ran: ${picked.reason}` : `${picked.reason}; this turn runs on ${picked.model}` }, Date.now())]), picked.model === null ? (() => { throw new Error(`paid model refused (${picked.reason})`) })() : [(row.model = picked.model), b.sql.exec(`UPDATE cb_turn SET model = ? WHERE id = ?`, row.model, id)]]
        const model = b.models.model(row.model)
        const root = await (await piOpen).root(BACKGROUND_CONTEXT)
        mark("pi")
        await root.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: b.models.thinking(row.model) }, BACKGROUND_CONTEXT)
        // A fresh context every turn: the model sees the view, the new messages and its own tool loop.
        // The previous turns' pi entries are never read again (each turn starts a fresh context): pruned when allowed.
        if (b.doEnv.CHIEF_BRAIN_PRUNE_PI === "1") {
          const p = prunePiEntries(b.sql)
          if (p.deleted > 0 || p.skipped.length > 0) console.log(JSON.stringify({ msg: "chief_brain.pi_pruned", run: id, deleted: p.deleted, skipped: p.skipped.slice(0, 3) }))
        }
        await b.harness.session().reset()
        b.sql.exec(`UPDATE cb_turn SET submitted = 1 WHERE id = ?`, id)
        // The tool set is fixed here for the whole turn (from the last check); the next check runs off the hot path
        // and takes effect at the next turn boundary.
        b.startTurnHands()
        b.doCtx.waitUntil(b.refreshHands().catch(() => undefined))
        mark("submit")
        await b.harness.submit(blocks.map((text) => ({ type: "text" as const, text })), { operationId: id })
      }
      // A child's bound runs from its start, across restarts (its slot frees after SLOT_STALE_MS).
      const left = child ? Math.max(1_000, Number(b.sql.exec<{ s: number }>(`SELECT started AS s FROM cb_turn WHERE id = ?`, id).one().s) + TURN_MS - Date.now()) : TURN_MS
      const limit = new Promise<"timeout">((r) => (timer = setTimeout(() => r("timeout"), left)))
      b.turnLive = true
      // After a restart: the ops that joined this turn before (pi takes a repeated operation id once).
      for (const s of b.steerOps(id)) [b.steered.push(s.op), await b.harness.session().steer([{ type: "text" as const, text: s.text }], { operationId: s.op }).catch(() => undefined)]
      // Messages of a burst that came while the turn was being set up (admitted, not live yet) join it now,
      // instead of starting a second run after it.
      if (!child) await b.steerQueued(row.conversation)
      let result = await Promise.race([b.harness.wait(id), limit])
      // Messages that joined the turn: wait for them as well (one that came after the last step runs on, under this turn).
      for (let i = 0; i < b.steered.length && result !== "timeout"; i++) {
        const joined = await Promise.race([b.harness.wait(b.steered[i]!), limit])
        if (joined === "timeout" || joined.status !== "done") result = joined
      }
      // The turn made or found the Chief's first hand: one continuation in the same run, with the full tools (the
      // tools list changes only between pi turns; the finished turn's thinking is dropped from the continuation's
      // requests by stripStaleThinking, since the route checks every replayed block). At most one per run.
      const cont = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `hands_cont:${id}`).toArray()[0]?.value
      const steeredBefore = b.steered.length
      if (!child && result !== "timeout" && result.status === "done" && (cont === "pending" || cont === "submitted")) {
        if (cont === "pending") writeConfig(b.sql, { [`hands_cont:${id}`]: "submitted" })
        b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'continuation', ?) ON CONFLICT DO NOTHING`, id, Date.now())
        b.startTurnHands()
        // pi takes a repeated operation id once, so a resumed turn submits again safely.
        const info = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `hands_cont_info:${id}`).toArray()[0]?.value
        await b.harness.submit([{ type: "text" as const, text: handsContinueText(info, b.doEnv.HAND_SANDBOX_WORKDIR || "/root/proj") }], { operationId: `${id}:hands` })
        result = await Promise.race([b.harness.wait(`${id}:hands`), limit])
        // Messages that joined during the continuation: wait for them too.
        for (let i = steeredBefore; i < b.steered.length && result !== "timeout"; i++) {
          const joined = await Promise.race([b.harness.wait(b.steered[i]!), limit])
          if (joined === "timeout" || joined.status !== "done") result = joined
        }
      }
      // No message joins from here on: the next one starts its own turn.
      b.turnLive = false
      if (result === "timeout") {
        for (const op of [id, `${id}:hands`, ...b.steered]) void b.harness.abort({ operationId: op }).catch(() => undefined)
        reason = "timeout"
      } else {
        ok = result.status === "done"
        reason = ok ? null : (result.reason ?? "unknown")
      }
    }
  } catch (e) {
    reason = e instanceof Error ? e.message : String(e)
  } finally {
    clearTimeout(timer)
    b.turnLive = false
    b.steered = []
    b.sql.exec(`DELETE FROM cb_config WHERE name IN (?, ?, ?, ?)`, `steer:${id}`, `hands_cont:${id}`, `hands_cont_info:${id}`, `marks:${id}`)
    b.turnId = undefined
    b.turnConversation = undefined
  }
  if (child) return b.childEnd(id, ok, reason)
  const reply = ok ? lastTalk(b.sql, id) : ""
  const post = !ok ? "none" : reply === "" || isNoReply(reply) ? "no_reply" : "pending"
  b.sql.exec(`UPDATE cb_turn SET status = ?, reason = ?, ended = ?, input = NULL, reply = ?, post = ? WHERE id = ?`, ok ? "done" : "failed", reason, Date.now(), post === "pending" ? clipReply(linkIds(reply)) : null, post, id)
  b.sql.exec(`UPDATE cb_inbox SET state = ? WHERE turn = ?`, ok ? "done" : "failed", id)
  if (!ok) [console.warn(JSON.stringify({ msg: "chief_brain.turn_failed", run: id, reason: String(reason).slice(0, 300), error: runError(b.sql, id)?.slice(0, 300) })), await turnFailedNotice(b.doEnv, b.sql, b.config(), row.conversation, id, String(reason), runError(b.sql, id))]
  b.announce(id, [])
  if (post === "pending") await b.postAndSchedule(id)
  else await b.finish(id)
  if (!b.memory.settled()) await b.schedule("compact", "compact", Date.now() + RETRY_MS)
}

export async function postAndSchedule(b: ChiefBrainDO, id: string): Promise<void> {
  const next = await liveOf(b.doCtx).after(async () => undefined).then(() => b.post(id)) // the final delta and the run end reach members before the reply
  if (next !== null) await b.schedule(`post:${id}`, "post", next)
}

/**
 * Posts the run's reply as the chief. Returns when to try again (the loop guard's agent_rate, or no
 * answer), or null when done; done acks the wakes.
 */
export async function post(b: ChiefBrainDO, id: string): Promise<number | null> {
  if (b.posting.has(id)) return null
  b.posting.add(id)
  try {
    if (b.childOf()) return await b.childReport(id)
    const t = b.sql.exec<{ conversation: string; trigger_message: string; trigger_kind: string; trigger_thread_root: string | null; reply: string | null; post: string; post_tries: number; post_key: number; ended: number | null }>(`SELECT conversation, trigger_message, trigger_kind, trigger_thread_root, reply, post, post_tries, post_key, ended FROM cb_turn WHERE id = ?`, id).toArray()[0]
    const cfg = b.config()
    if (!t || t.post !== "pending" || !t.reply || !cfg.agent || !cfg.owner) return null
    // The chief may have been archived or placed on a server since the turn began.
    const a = await b.admitted(cfg.agent, cfg.owner, false).catch((): Admission => ({ ok: false, reason: "owner.unreachable" }))
    const steps = Number(b.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM cb_step WHERE turn = ?`, id).one().n)
    // The ledger replays a refusal under the same key, so a refused try's retry needs a new key (the
    // key is also the client message id); an unknown outcome (no answer) retries under the same key.
    const key = `chief-reply:${cfg.agent}:${id}:${t.post_key}`
    const res = !a.ok
      ? { ok: false as const, code: a.reason, message: a.reason }
      : await postReply(b.doEnv, chiefPrincipal(cfg.agent, cfg.owner), { conversation: t.conversation, text: t.reply, run: { id, host: `${HOST}:${cfg.agent}`, steps }, ...replyTarget(t.trigger_kind, t.trigger_message, t.trigger_thread_root), key }).catch(
          (e: unknown) => ({ ok: false as const, code: "owner.unreachable", message: String(e) })
        )
    if (!res.ok && retryPost(res.code, t.post_tries, t.ended, Date.now())) {
      b.sql.exec(`UPDATE cb_turn SET post_tries = post_tries + 1, post_key = post_key + ? WHERE id = ?`, res.code === "agent_rate" ? 1 : 0, id)
      return Date.now() + POST_RETRY_MS
    }
    if (res.ok) b.sql.exec(`UPDATE cb_turn SET post = 'posted', posted_message = ?, turn_key = ? WHERE id = ?`, res.message, key, id)
    else b.sql.exec(`UPDATE cb_turn SET post = 'refused', reason = ? WHERE id = ?`, res.code, id)
    b.announce(id, [])
    await b.finish(id)
    return null
  } finally {
    b.posting.delete(id)
  }
}

/** Typing off and the wake cursor moved past the run's messages. */
export async function finish(b: ChiefBrainDO, id: string): Promise<void> {
  const t = b.sql.exec<{ conversation: string; last_seq: number }>(`SELECT conversation, last_seq FROM cb_turn WHERE id = ?`, id).toArray()[0]
  const cfg = b.config()
  if (!t || !cfg.agent || !cfg.owner) return
  await typing(b.doEnv, t.conversation, cfg.agent, false)
  await ackWake(b.doEnv, cfg.agent, chiefPrincipal(cfg.agent, cfg.owner), t.conversation, t.last_seq).catch(() => undefined)
}
