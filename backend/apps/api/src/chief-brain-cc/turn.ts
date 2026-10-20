import type { AssistantMessageEvent } from "@earendil-works/pi-ai"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { addUsage, clip, clipInput, upsertStep } from "../chief-brain/brain-runs.ts"
import { liveOf } from "../chief-brain/brain-stream.ts"
import { typing } from "../chief-brain/brain-io.ts"
import { systemPrompt } from "../chief-brain/prompts.ts"
import { isClaude, OPUS } from "../model-gateway/routes.ts"
import { BOOT_MS, CcError, createVm, execRoot, mintTailnetKey, removeVm, vmName } from "./vm.ts"

/**
 * One Cloud Chief turn as Claude Code (the personal route, vm.ts): the conversation brain (ChiefBrainDO
 * `<agent>/<conversation>`) keeps everything it does for a pi turn (inbox, admission, the one memory and
 * its view, typing, the run and its steps, live frames, the post and the wake ack); only the model loop
 * moves: a fresh VM gets the turn's input (the same view and new messages a pi turn gets,
 * Memory.turnInput) and the Chief's system prompt, runs `claude -p` once, and sends its stream back to
 * POST /v1/chief-cc/<agent>/<conversation>/notes with a token made for this turn only. The final text
 * becomes the run's talk step and is appended to the memory log, as a pi reply is; tool calls are logged
 * there too, so the Chief stays one memory across its turns.
 *
 * Restart safety: the VM id and the token's hash are in cb_config before the VM is told to run. A turn
 * that resumes after an eviction waits on the same VM (its result file, /run/chief/<run>.out) until the
 * deadline counted from its first start; a VM made but never started is deleted and the turn starts
 * again; a started turn whose VM is gone is never run a second time (its posted reply stands, else it
 * failed).
 */
export const CC_NOTES_PATH = /^\/v1\/chief-cc\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/notes$/
/** stdin is at most 1 MiB decoded (Freestyle exec): the oldest part of the view goes when the input is larger. */
const STDIN_BYTES = 1_000_000
/** One argument of `claude` (--append-system-prompt); the kernel's limit is 128 KiB. */
const SYSTEM_BYTES = 100_000
/** The notes post is the main path; the result file is read this often, and the typing indicator renewed. */
const POLL_MS = 15_000
const RUN_MS = 9 * 60_000

export const CC_ADDENDUM = `## This route
You run as Claude Code in a fresh Linux machine that is deleted after this turn: nothing you write there
is kept. The view's zoom and date tools are not available here; answer from the view and the new
messages. Your last message is posted as your reply, so it must be the reply itself. Say in it what you
learned that will matter later: the view is your only memory.`

export interface CcResult {
  readonly status: "done" | "failed"
  readonly reply: string
  readonly error?: string
  readonly usage?: { input: number; output: number; cache_read: number; cache_write: number }
  readonly first_token_ms?: number | null
  readonly total_ms?: number
  readonly last_gen?: number
}
type Ev = { gen: number; type: string; delta?: string; text?: string; id?: string; name?: string; input?: unknown; error?: boolean }

const sha = async (s: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("")
const cfgOf = (b: ChiefBrainDO, name: string) => b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, name).toArray()[0]?.value
const enc = new TextEncoder()
/** Its size as a JSON string value in UTF-8 (how it travels in the turn's input). */
const jsonBytes = (text: string) => enc.encode(JSON.stringify(text)).length
/** The newest part of `text` that fits `max` bytes as JSON (the oldest part of the view goes first, with a note). */
export const tail = (text: string, max: number): string => {
  if (jsonBytes(text) <= max) return text
  let [lo, hi] = [0, text.length]
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2)
    if (jsonBytes(text.slice(text.length - mid)) <= max - 100) lo = mid
    else hi = mid - 1
  }
  return `[... the oldest part of the view is cut here ...]\n${text.slice(text.length - lo)}`
}
const clipBytes = (text: string, max: number) => (enc.encode(text).length <= max ? text : new TextDecoder().decode(enc.encode(text).slice(0, max)))
const markAt = (b: ChiefBrainDO, id: string, m: string) => b.sql.exec<{ at: number }>(`SELECT at FROM cb_marks WHERE turn = ? AND mark = ?`, id, m).toArray()[0]?.at

/**
 * The notes token of one turn: `<nonce>.<mac>`, the mac over agent, conversation, run and nonce with a key
 * derived from a Worker secret, so the notes route checks it before it wakes any object; the object then
 * checks that it is the running turn's (its hash in cb_config).
 */
const macKey = (env: ChiefBrainDO["doEnv"]) =>
  crypto.subtle.digest("SHA-256", enc.encode(`chief-cc-notes:${env.CHIEF_CC_TS_OAUTH ?? ""}`)).then((k) => crypto.subtle.importKey("raw", k, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]))
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("")
const macOf = async (env: ChiefBrainDO["doEnv"], agent: string, conversation: string, run: string, nonce: string) => hex(await crypto.subtle.sign("HMAC", await macKey(env), enc.encode(`${agent}/${conversation}/${run}/${nonce}`)))
const notesToken = async (env: ChiefBrainDO["doEnv"], agent: string, conversation: string, run: string) => {
  const nonce = crypto.randomUUID().replace(/-/g, "")
  return `${nonce}.${await macOf(env, agent, conversation, run, nonce)}`
}
/** The Worker's check of a notes token, before any object is woken. */
export const notesTokenOk = async (env: ChiefBrainDO["doEnv"], agent: string, conversation: string, run: string, token: string): Promise<boolean> => {
  const m = /^([0-9a-f]{32})\.([0-9a-f]{64})$/.exec(token)
  if (!m || !/^run_[0-9]{1,15}$/.test(run)) return false
  const want = enc.encode(await macOf(env, agent, conversation, run, m[1]!))
  const got = enc.encode(m[2]!)
  let diff = 0
  for (let i = 0; i < want.length; i++) diff |= want[i]! ^ got[i]!
  return diff === 0
}

/** Waiters of the turns this object runs (the notes route resolves them). */
const waiters = new WeakMap<ChiefBrainDO, Map<string, (r: CcResult) => void>>()
const waitersOf = (b: ChiefBrainDO) => {
  let m = waiters.get(b)
  if (!m) waiters.set(b, (m = new Map()))
  return m
}
/** The generation each run's live stream is on (BrainStream starts a generation per model message). */
const gens = new WeakMap<ChiefBrainDO, Map<string, number>>()
const genOf = (b: ChiefBrainDO) => {
  let m = gens.get(b)
  if (!m) gens.set(b, (m = new Map()))
  return m
}

export async function ccTurn(b: ChiefBrainDO, id: string, blocks: ReadonlyArray<string>, model: string, submitted: boolean): Promise<{ ok: boolean; reason: string | null }> {
  const env = b.doEnv
  const cfg = b.config()
  const agent = cfg.agent!
  const conversation = b.turnConversation!
  const mark = (m: string) => void b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, id, m, Date.now())
  let vm = cfgOf(b, `cc_vm:${id}`)
  // Started, and its VM already gone (this object stopped after the turn ended): never run it a second time.
  if (submitted && !vm) return markAt(b, id, "cc_ok") !== undefined ? { ok: true, reason: null } : { ok: false, reason: "the turn machine was lost" }
  if (vm && !submitted) {
    if (!(await removeVm(env, vm))) return { ok: false, reason: "the earlier turn machine could not be removed" }
    b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, `cc_vm:${id}`)
    vm = undefined
  }
  const result = new Promise<CcResult>((r) => waitersOf(b).set(id, r))
  try {
    if (!vm) {
      const name = vmName(env)
      vm = await createVm(env, name, { agent, conversation, run: id })
      writeConfig(b.sql, { [`cc_vm:${id}`]: vm })
      mark("vm")
      const key = await mintTailnetKey(env)
      const boot = await execRoot(env, vm, `/opt/chief-cc/boot.sh ${name}`, key, BOOT_MS)
      if (boot.exit !== 0 || !boot.stdout.includes("ready")) throw new CcError(`the turn machine did not join the network (exit ${boot.exit})`)
      mark("vm_ready")
      const token = await notesToken(env, agent, conversation, id)
      writeConfig(b.sql, { [`cc_token:${id}`]: await sha(token) })
      const origin = (env.CLOUD_API_ORIGIN ?? "").replace(/\/+$/, "")
      const input = {
        notes_url: `${origin}/v1/chief-cc/${agent}/${conversation}/notes`,
        token,
        model: isClaude(model) ? model : OPUS,
        system: clipBytes(`${systemPrompt(cfg)}\n\n${CC_ADDENDUM}`, SYSTEM_BYTES),
        prompt: "",
        max_ms: RUN_MS
      }
      input.prompt = tail(blocks.join("\n\n"), STDIN_BYTES - enc.encode(JSON.stringify(input)).length)
      const started = await execRoot(env, vm, `/opt/chief-cc/start.sh ${id}`, enc.encode(JSON.stringify(input)), 30_000)
      if (started.exit !== 0) throw new CcError(`the turn did not start (exit ${started.exit})`)
      b.sql.exec(`UPDATE cb_turn SET submitted = 1 WHERE id = ?`, id)
      mark("submit")
      genOf(b).set(id, 0)
      liveOf(b.doCtx).request(`${id}.0`)
    }
    // Counted from the turn's first start (a resumed turn does not get a new deadline).
    const deadline = (markAt(b, id, "submit") ?? Date.now()) + RUN_MS + 30_000
    let r: CcResult | null = null
    while (r === null && Date.now() < deadline) {
      let timer: ReturnType<typeof setTimeout> | undefined
      r = await Promise.race([result, new Promise<null>((ok) => (timer = setTimeout(() => ok(null), Math.max(0, Math.min(POLL_MS, deadline - Date.now())))))])
      clearTimeout(timer)
      if (r !== null) break
      // The typing indicator stays on while the machine works (a pi turn renews it at each model request);
      // awaited, so it never lands after the turn's own typing(false).
      await typing(env, conversation, agent, true).catch(() => undefined)
      // The notes post may be lost (or this object restarted): the result file is the truth.
      r = await Promise.race([result, readOut(b, vm, id)])
    }
    if (r === null) return { ok: false, reason: "timeout" }
    return finishTurn(b, id, r)
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    b.sql.exec(`INSERT INTO cb_run_error (turn, text) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET text = excluded.text`, id, message.slice(0, 400))
    return { ok: false, reason: message }
  } finally {
    waitersOf(b).delete(id)
    gens.get(b)?.delete(id)
    if (vm && (await removeVm(env, vm))) b.sql.exec(`DELETE FROM cb_config WHERE name IN (?, ?)`, `cc_vm:${id}`, `cc_token:${id}`)
    else b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, `cc_token:${id}`)
  }
}

const readOut = async (b: ChiefBrainDO, vm: string, id: string): Promise<CcResult | null> => {
  const r = await execRoot(b.doEnv, vm, `cat /run/chief/${id}.out 2>/dev/null || true`, null, 10_000).catch(() => null)
  if (!r?.stdout.trim()) return null
  try {
    return JSON.parse(r.stdout) as CcResult
  } catch {
    return null
  }
}

const finishTurn = (b: ChiefBrainDO, id: string, r: CcResult): { ok: boolean; reason: string | null } => {
  if (r.usage) addUsage(b.sql, id, { ...r.usage, cost_usd: 0 })
  if (typeof r.total_ms === "number") b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'cc_done', ?) ON CONFLICT DO NOTHING`, id, Date.now())
  if (r.status !== "done") {
    b.sql.exec(`INSERT INTO cb_run_error (turn, text) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET text = excluded.text`, id, String(r.error ?? "the agent failed").slice(0, 400))
    return { ok: false, reason: String(r.error ?? "the agent failed").slice(0, 300) }
  }
  const reply = String(r.reply ?? "").trim()
  // The reply is the run's last talk step (its live step id, so the row replaces the streamed text) and a memory line.
  if (reply) b.logOnce(`talk:${id}`, "talk", reply, { id: `talk:${id}.${r.last_gen ?? 0}`, kind: "talk", ...clip(reply), ended_at: Date.now() })
  b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'cc_ok', ?) ON CONFLICT DO NOTHING`, id, Date.now())
  return { ok: true, reason: null }
}

/**
 * The turn machine's stream (the Worker routed POST .../notes here): a token made for the running turn only;
 * events become live frames (BrainStream, as a pi model stream) and tool steps; the result ends the wait.
 */
export async function ccNotes(b: ChiefBrainDO, token: string, body: { run?: unknown; events?: unknown; result?: unknown }): Promise<{ status: number }> {
  const run = typeof body.run === "string" ? body.run : ""
  const want = /^run_[0-9]{1,15}$/.test(run) ? cfgOf(b, `cc_token:${run}`) : undefined
  if (!want || !token || want !== (await sha(token)) || b.turnId !== run) return { status: 401 }
  const live = liveOf(b.doCtx)
  const g = genOf(b)
  for (const e of Array.isArray(body.events) ? (body.events as Array<Ev>).slice(0, 2000) : []) {
    const gen = Number(e.gen) || 0
    // A new model message (or the first event after this object restarted) starts a generation of the live stream.
    if (gen !== g.get(run)) [g.set(run, gen), live.request(`${run}.${gen}`)]
    const ev = (x: unknown) => live.event(x as AssistantMessageEvent)
    switch (e.type) {
      case "text_start":
      case "thinking_start":
        ev({ type: e.type })
        break
      case "text_delta":
      case "thinking_delta":
        if (typeof e.delta === "string") ev({ type: e.type, delta: e.delta })
        break
      case "text_done":
        if (typeof e.text === "string" && e.text.trim()) b.announce(run, [upsertStep(b.sql, run, { id: `talk:${run}.${gen}`, kind: "talk", ...clip(e.text), ended_at: Date.now() }, Date.now())])
        break
      case "tool": {
        if (typeof e.id !== "string" || typeof e.name !== "string") break
        const name = e.name.slice(0, 80)
        ev({ type: "toolcall_start" })
        ev({ type: "toolcall_end", toolCall: { name, arguments: e.input ?? {} } })
        // The memory line is short (the view has no compactor on this route): the name and the start of the input.
        b.logOnce(`tool:${e.id}`, "tool", `${name} ${JSON.stringify(e.input ?? {}).slice(0, 200)}`, { id: `tool:${e.id}`, kind: "tool", status: "running", tool: { name, input: clipInput(e.input), started_at: Date.now() } })
        break
      }
      case "tool_done":
        if (typeof e.id === "string") b.announce(run, [upsertStep(b.sql, run, { id: `tool:${e.id}`, kind: "tool", status: e.error ? "failed" : "done", ended_at: Date.now() } as never, Date.now())])
        break
      case "done":
        ev({ type: "done" })
        break
      default:
    }
  }
  if (body.result && typeof body.result === "object") waitersOf(b).get(run)?.(body.result as CcResult)
  return { status: 200 }
}
