import type { AssistantMessageEvent } from "@earendil-works/pi-ai"
import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { addUsage, clip, clipInput, lastTalk, readSteps, upsertStep } from "../chief-brain/brain-runs.ts"
import { CC_PARTIAL } from "../chief-brain/brain-gateway.ts"
import { liveOf } from "../chief-brain/brain-stream.ts"
import { typing } from "../chief-brain/brain-io.ts"
import { systemPrompt } from "../chief-brain/prompts.ts"
import { isClaude, OPUS } from "../model-gateway/routes.ts"
import { netScript, patchNet, readNet } from "./net.ts"
import { legacyOf, sandboxesOf } from "./sandbox.ts"
import { CHIEF_VM_MJS } from "./chief-vm-source.ts"
import { stageAttachments } from "./attachments.ts"
import { mergeTurnFiles, toolsOf } from "./tools.ts"
import { githubLine, githubOf } from "./github.ts"
import { wakeCall } from "./wake.ts"
import { autoCall } from "./jobs.ts"
import { BOOT_MS, CcError, RUN_MS, createVm, execRoot, mintTailnetKey, removeVm, vmName, vmNetwork } from "./vm.ts"

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
 *
 * Never silent (Lawrence, Oct 24): a machine that did not start is replaced (two more tries, with backoff); a model
 * error before any tool ran is run once more on a fresh machine; a turn that ends early otherwise (the time
 * limit, a model error after its tools ran) posts the text it had streamed, after one plain line saying so. Only a
 * turn with nothing to show fails, and its notice says what happened (brain-gateway.ts CC_NOTICES).
 */
export const CC_NOTES_PATH = /^\/v1\/chief-cc\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/notes$/
/** stdin is at most 1 MiB decoded (Freestyle exec): the oldest part of the view goes when the input is larger. */
const STDIN_BYTES = 1_000_000
/** One argument of `claude` (--append-system-prompt); the kernel's limit is 128 KiB. */
const SYSTEM_BYTES = 100_000
/** The notes post is the main path; the result file is read this often, and the typing indicator renewed. */
const POLL_MS = 15_000
/** A machine that did not start is replaced this many times, after these waits. */
const START_RETRY_MS = [2_000, 8_000]

/** The route's part of the system prompt, with the turn's time. */
export const ccAddendum = (minutes: number): string => `## This route
You have ${minutes} minutes for this turn; then the machine stops and what you wrote so far is posted. For longer
work, start it elsewhere (\`chief-agents spawn\`, or a sandbox with \`chief-vm\`) and answer with what you started
and how to follow it; check on it in a later turn.
You run as Claude Code in a fresh Linux machine that is deleted after this turn: nothing you write there
is kept (keep work in a sandbox VM or push it). The view's zoom and date tools are not available here;
answer from the view and the new messages. Your last message is posted as your reply, so it must be the
reply itself. Say in it what you learned that will matter later: the view is your only memory.

Machine: ~/work/cmux (feat-cmux-next) and ~/work/cmuxterm-hq (main) are cached clones; \`git fetch\` first.
GitHub: gh and git are signed in (check with \`gh auth status\`) with this Chief's own login when it has one
(\`chief-github\`; the line at the end says), else the deployment's; push cmux work to feat-cmux-next (rebase,
plain push, never force).
Tailnet: this machine is your own tailnet node (\`tailscale status\`). It reaches the hub at
http://100.127.110.65:8790 (\`hub\`, the Mac Chief <-> Cloud Chief channel), the build controller
(\`cmux-ci\`, macOS builds on the Mac minis) and the person's Mac gate.
Attachments: a message's attached file (a pasted screenshot, a photo, a PDF) is in this machine at the
path its line names (\`[attachment: NAME, TYPE WxH SIZE, file /home/chief/work/.attachments/...]\`); open it
with Read (images too) before you answer about it. Later turns see only your words, so say in your reply
what a picture shows that will matter later.
Mac: \`mac -- COMMAND\` runs one command on the person's MacBook (as them; every call is logged there);
\`mac health\` answers at once, and says "Mac asleep" when the laptop sleeps. \`cmux ...\` here is the
Mac's cmux CLI through the gate.
Agents: \`chief-agents peers\` lists the Mac Chief's subagents, \`chief-agents spawn "Title: ...\\n task"\`
starts one there, \`chief-agents tell aN "message"\`, \`chief-agents control status|priority|cap ...\`.
These need the Mac awake.
Sandboxes: \`chief-vm list|get|cap|create|update|resize|pause|start|stop|exec|delete\`:
Linux VMs of your own that outlive this turn (12 h by default, paused when idle; \`chief-vm cap\` shows how
many you may keep). New ones are Ubuntu 24.04 on a 16 GB disk with 4 vCPU / 8 GiB (\`--image chief\` for your
machine image with its tools, 32 GB); \`chief-vm resize ID --cpu 8 --memory-gb 16 --disk-gb 64\` grows one (grow
only, the filesystem too) and \`create\` takes the same flags; list, get, create and resize show the size and cost
per hour. \`exec ID [--user root|chief] [--env K=V] [--stdin FILE] -- COMMAND\`.
Network: by default you reach the public Internet over IPv4 and IPv6 with DNS, and the tailnet; private
addresses and other local ports are closed. \`chief-net show\`, \`chief-net set internet=on|off dns=on|off
tailnet=on|off local=on|off\`, \`chief-net allow|deny|unallow|undeny HOST-OR-RANGE...\`, \`chief-net reset\`
change it for this machine at once and for your next turns.
Timers: \`chief-wake SECONDS "note"\` (30 s to 24 h) wakes you later with "[wake] note" as a new turn; \`chief-wake
list|clear\`. Use it to come back to something (a sign-in code that ends, a deploy) instead of waiting.
Jobs: when the person asks for something recurring or triggered ("every morning", "each Friday", "when
GitHub calls this URL"), make it a job: \`chief-auto add [--tz Area/City] NAME WHEN "PROMPT"\` (WHEN is a 5-field cron,
\`webhook\` or \`manual\`; PROMPT is the whole task, it is all a later run sees). Each run posts "[job ID] PROMPT"
here as your own note and starts a turn in the cloud while the person's computers sleep: do the job then and post
the result in this chat. \`chief-auto ls|run ID|rm ID\`. Say in one line what you made and when it next runs.
Paid plans: when a step answers \`automation.plan.required\` (or \`cloud.plan.required\`, or credits ran out), send
the person one line: what the plan adds and its price, with its "checkout" link as a Markdown link; nothing is
charged until they pay on that page. Never say you bought or upgraded anything, never name the payment provider, and
send it once per ask. When they pay, a "[billing] ... is on" note starts a turn: say in one line that the plan is on
and redo the step that needed it (the same \`chief-auto add\`) without asking.
Your own tools: \`chief-tools put PATH FILE\` keeps a file for all your next turns and writes it here now;
\`chief-tools ls\`, \`chief-tools rm PATH\`. PATH is .local/bin/NAME (a command on your PATH),
.claude/skills/NAME/SKILL.md (a skill), .claude/agents/NAME.md or .chief/tools/...; at most 64 KB a file,
256 KB in all. Add or fix a tool this way instead of waiting for a new machine image.
Skills: the skills every Chief ships with are Native/OptChat/optchat-chief/skills/NAME/SKILL.md in ~/work/cmux; read
the latest with \`git -C ~/work/cmux fetch -q origin feat-cmux-next && git -C ~/work/cmux show
FETCH_HEAD:Native/OptChat/optchat-chief/skills/NAME/SKILL.md\`. When the person mentions their phone or being away from the desk,
another computer (a Mac, a Linux server), Tailscale, or asks what else cmux can do, read cmux-adoption and follow it:
check their setup first (its commands run on their Mac as \`cmux ...\`), then offer the one step that fits (the
iPhone app and pairing, cmux on the other computer joined over Tailscale), once, in plain words.`

/** Writes the Worker's `chief-vm` client over the snapshot's (root; the wrapper /usr/local/bin/chief-vm runs it). */
const toolsScript = (): string => {
  const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(CHIEF_VM_MJS)))
  return `printf %s '${b64}' | base64 -d > /opt/chief-cc/chief-vm.mjs.new && chmod 644 /opt/chief-cc/chief-vm.mjs.new && mv /opt/chief-cc/chief-vm.mjs.new /opt/chief-cc/chief-vm.mjs`
}

/** The Chief's tool files (CHIEF_CC_TURN_FILES): relative paths under /home/chief to text, or {} when unset or not well formed. */
export const turnFiles = (raw: string | undefined): Record<string, string> => {
  try {
    const o = JSON.parse(raw ?? "{}") as Record<string, unknown>
    if (!o || typeof o !== "object" || Array.isArray(o)) return {}
    const out: Record<string, string> = {}
    for (const [k, v] of Object.entries(o)) if (typeof v === "string" && /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/.test(k) && !k.split("/").includes("..") && v.length <= 64_000) out[k] = v
    return out
  } catch {
    return {}
  }
}

export interface CcResult {
  /** partial: it ended early (`reason`) with text written so far in `reply` (a runner that keeps it). */
  readonly status: "done" | "failed" | "partial"
  readonly reply: string
  readonly error?: string
  readonly reason?: "timeout" | "model" | "stopped"
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
/** Run.timing (cb_timing, as a pi turn's gateway calls write it): the turn's request, and its first streamed token as the Worker got it. */
const timing = (b: ChiefBrainDO, id: string, mark: "request" | "first_token") =>
  void b.sql.exec(`INSERT INTO cb_timing (turn, ${mark}_at) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET ${mark}_at = COALESCE(${mark}_at, excluded.${mark}_at)`, id, Date.now())
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
  const vm = cfgOf(b, `cc_vm:${id}`)
  // Started, and its VM already gone (this object stopped after the turn ended): never run it a second time.
  if (submitted && !vm) return markAt(b, id, "cc_ok") !== undefined ? { ok: true, reason: null } : endEarly(b, id, "stopped", "the turn machine was lost", null)
  if (vm && !submitted) {
    if (!(await removeVm(env, vm))) return { ok: false, reason: "cc_machine: the earlier turn machine could not be removed" }
    b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, `cc_vm:${id}`)
  }
  let resume = submitted
  let startRetries = 0
  let modelRetried = false
  for (;;) {
    const a = await ccAttempt(b, id, blocks, model, resume)
    resume = false
    if (a.unstarted !== undefined) {
      // Nothing ran on that machine: a fresh one, after a short wait.
      const wait = START_RETRY_MS[startRetries++]
      console.warn(JSON.stringify({ msg: "chief_cc.start_failed", run: id, error: a.unstarted.slice(0, 200), retry: wait !== undefined }))
      if (wait === undefined) return runError(b, id, a.unstarted), { ok: false, reason: `cc_machine: ${a.unstarted}`.slice(0, 300) }
      b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, id, `cc_retry_start_${startRetries}`, Date.now())
      await new Promise((r) => setTimeout(r, wait))
      continue
    }
    const r = a.result ?? null
    if (r?.status === "done") return finishTurn(b, id, r)
    if (r?.usage) addUsage(b.sql, id, { ...r.usage, cost_usd: 0 })
    const kind = a.lost ? "stopped" : endKind(r)
    // A model error before any tool ran or any text was written has no side effects: once more, on a fresh machine.
    if (kind === "model" && !modelRetried && !toolsRan(b, id) && !textOf(b, id, r)) {
      modelRetried = true
      console.warn(JSON.stringify({ msg: "chief_cc.model_retry", run: id, error: String(r?.error ?? "").slice(0, 200) }))
      b.sql.exec(`UPDATE cb_turn SET submitted = 0 WHERE id = ?`, id)
      b.sql.exec(`DELETE FROM cb_marks WHERE turn = ? AND mark = 'submit'`, id)
      b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'cc_retry_model', ?) ON CONFLICT DO NOTHING`, id, Date.now())
      continue
    }
    const nothingRan = kind === "model" && modelRetried && !toolsRan(b, id) && !textOf(b, id, r)
    return endEarly(b, id, nothingRan ? "model_before" : kind, a.lost ?? String(r?.error ?? (r ? "the agent failed" : "no result by the deadline")), r)
  }
}

/** One machine for the turn: made, booted and started (or, resumed, the one it has), then its result; the machine is removed after. */
const ccAttempt = async (b: ChiefBrainDO, id: string, blocks: ReadonlyArray<string>, model: string, resume: boolean): Promise<{ result?: CcResult | null; unstarted?: string; lost?: string }> => {
  const env = b.doEnv
  const cfg = b.config()
  const agent = cfg.agent!
  const conversation = b.turnConversation!
  const mark = (m: string) => void b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING`, id, m, Date.now())
  let vm = resume ? cfgOf(b, `cc_vm:${id}`) : undefined
  let started = resume
  const result = new Promise<CcResult>((r) => waitersOf(b).set(id, r))
  try {
    if (!vm) {
      const name = vmName(env)
      // Nothing below the create depends on the VM until the boot: the tailnet key, the turn token, the Chief's GitHub login and its tool
      // files are asked for while the machine is made (each was a serial round trip on the first-token path). A failure surfaces where the
      // value is used; the catch only keeps a rejection that lands before then from being unhandled.
      const keyP = mintTailnetKey(env)
      const prepP = Promise.all([notesToken(env, agent, conversation, id), githubOf(env, agent).ccGithubTurn(agent), toolsOf(env, agent).ccToolFiles()])
      keyP.catch(() => undefined)
      prepP.catch(() => undefined)
      vm = await createVm(env, name, { agent, conversation, run: id })
      writeConfig(b.sql, { [`cc_vm:${id}`]: vm })
      mark("vm")
      const providerP = vmNetwork(env, vm)
      providerP.catch(() => undefined)
      const boot = await execRoot(env, vm, `/opt/chief-cc/boot.sh ${name}`, await keyP, BOOT_MS)
      if (boot.exit !== 0 || !boot.stdout.includes("ready")) throw new CcError(`the turn machine did not join the network (exit ${boot.exit})`)
      // The agent stays closed (boot.sh) until the Chief's network settings are applied here.
      const net = readNet(cfgOf(b, "cc_net"))
      // The current `chief-vm` first (it ships with the Worker, not the snapshot), then the network settings; the attachments the input
      // names (pasted screenshots, files) are written meanwhile, where its lines say, before the agent starts.
      const [applied, staged] = await Promise.all([
        execRoot(env, vm, "bash -s", enc.encode(`${toolsScript()}\n${netScript(net)}`), 30_000),
        stageAttachments(env, vm, agent, cfg.owner ?? "", conversation, blocks.join("\n\n"))
      ])
      if (applied.exit !== 0 || !applied.stdout.includes("net ok")) throw new CcError(`the turn machine's network settings did not apply (exit ${applied.exit})`)
      mark("vm_ready")
      if (staged.written > 0) mark("attachments")
      const missingNote = staged.missing.length > 0 ? `\n\n[attachment files not available in this turn: ${staged.missing.map((m) => `${m.path} (${m.why})`).join("; ")}]` : ""
      const [token, github, toolFiles] = await prepP
      writeConfig(b.sql, { [`cc_token:${id}`]: await sha(token) })
      const origin = (env.CLOUD_API_ORIGIN ?? "").replace(/\/+$/, "")
      const input = {
        notes_url: `${origin}/v1/chief-cc/${agent}/${conversation}/notes`,
        token,
        model: isClaude(model) ? model : OPUS,
        system: clipBytes(`${systemPrompt(cfg)}\n\n${ccAddendum(RUN_MS / 60_000)}\n${githubLine(github.status)}`, SYSTEM_BYTES),
        prompt: "",
        max_ms: RUN_MS,
        net,
        provider: await providerP,
        // The agent user's tools: written as its files by chief-turn-runner (root) before Claude Code starts. The Chief's own
        // tools (chief-tools, tools.ts) come after the set ones and never on a token path.
        files: mergeTurnFiles(turnFiles(env.CHIEF_CC_TURN_FILES), toolFiles),
        github_token: github.token ?? env.CHIEF_CC_GITHUB_TOKEN ?? null
      }
      input.prompt = tail(blocks.join("\n\n") + missingNote, STDIN_BYTES - enc.encode(JSON.stringify(input)).length)
      const begun = await execRoot(env, vm, `/opt/chief-cc/start.sh ${id}`, enc.encode(JSON.stringify(input)), 30_000)
      if (begun.exit !== 0) throw new CcError(`the turn did not start (exit ${begun.exit})`)
      b.sql.exec(`UPDATE cb_turn SET submitted = 1 WHERE id = ?`, id)
      started = true
      mark("submit")
      timing(b, id, "request")
      genOf(b).set(id, 0)
      liveOf(b.doCtx).request(`${id}.0`)
    }
    // Counted from the turn's first start (a resumed turn does not get a new deadline).
    const deadline = (markAt(b, id, "submit") ?? Date.now()) + RUN_MS + 30_000
    // Nothing keeps this object in memory while the machine works: a job at the deadline brings an evicted
    // object back (onStart resumes this turn), so the turn always ends, with the reply when it is ready.
    await b.schedule(`cc-wake:${id}`, "drain", deadline + 5_000)
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
    // A turn resumed after its deadline (the object was evicted and came back late) never polled: the machine
    // may have finished long ago, so its result file is read once before the turn counts as timed out.
    r ??= await readOut(b, vm, id)
    return { result: r }
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    return started ? { result: null, lost: message } : { unstarted: message }
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
  const reply = String(r.reply ?? "").trim()
  // The reply is the run's last talk step (its live step id, so the row replaces the streamed text) and a memory line.
  if (reply) b.logOnce(`talk:${id}`, "talk", reply, { id: `talk:${id}.${r.last_gen ?? 0}`, kind: "talk", ...clip(reply), ended_at: Date.now() })
  b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'cc_ok', ?) ON CONFLICT DO NOTHING`, id, Date.now())
  return { ok: true, reason: null }
}

type EndKind = "timeout" | "model" | "stopped"
/**
 * Why a turn that did not finish ended: the runner says (`reason`); an older runner's result is read: SIGKILL at
 * the time limit is the timeout, Claude Code's own exit without a result is a stop, its error result the model's.
 * No result at all by the deadline is the timeout.
 */
const endKind = (r: CcResult | null): EndKind => {
  if (!r) return "timeout"
  if (r.reason === "timeout" || r.reason === "model" || r.reason === "stopped") return r.reason
  const error = String(r.error ?? "")
  if (/^claude exited on signal 9\b/.test(error) && (r.total_ms ?? 0) >= RUN_MS - 10_000) return "timeout"
  return /^claude exited /.test(error) ? "stopped" : "model"
}
const toolsRan = (b: ChiefBrainDO, id: string) => readSteps(b.sql, id, 0, 2000).some((s) => s.kind === "tool")
/** What the turn had written: the runner's partial reply, else its last finished text block (the run's last talk step). */
const textOf = (b: ChiefBrainDO, id: string, r: CcResult | null) => (r?.status === "partial" ? String(r.reply ?? "").trim() : "") || lastTalk(b.sql, id)
const runError = (b: ChiefBrainDO, id: string, text: string) => void b.sql.exec(`INSERT INTO cb_run_error (turn, text) VALUES (?, ?) ON CONFLICT (turn) DO UPDATE SET text = excluded.text`, id, text.slice(0, 400))

/**
 * A turn that ended early: with text, that text is the reply after one line saying what happened (the turn counts
 * as answered); without, it fails as `cc_<kind>` and the person gets that kind's notice (brain-gateway.ts CC_NOTICES).
 */
const endEarly = (b: ChiefBrainDO, id: string, kind: EndKind | "model_before", error: string, r: CcResult | null): { ok: boolean; reason: string | null } => {
  runError(b, id, error)
  const text = textOf(b, id, r)
  console.warn(JSON.stringify({ msg: "chief_cc.turn_ended_early", run: id, kind, tools: toolsRan(b, id), text: text.length, error: error.slice(0, 200) }))
  if (!text || kind === "model_before") return { ok: false, reason: `cc_${kind}: ${error}`.slice(0, 300) }
  const reply = `${CC_PARTIAL[kind]}\n\n${text}`
  // The runner's partial text is its own step (its generation); the last finished block's step otherwise, so the run shows it once.
  const step = r?.status === "partial" && r.reply.trim() ? `talk:${id}.${r.last_gen ?? 0}` : (readSteps(b.sql, id, 0, 2000).filter((s) => s.kind === "talk" && s.text).at(-1)?.id ?? `talk:${id}.0`)
  b.logOnce(`talk:${id}`, "talk", reply, { id: step, kind: "talk", ...clip(reply), ended_at: Date.now() })
  b.sql.exec(`INSERT INTO cb_marks (turn, mark, at) VALUES (?, 'cc_ok', ?) ON CONFLICT DO NOTHING`, id, Date.now())
  return { ok: true, reason: null }
}

/**
 * The turn machine's stream (the Worker routed POST .../notes here): a token made for the running turn only;
 * events become live frames (BrainStream, as a pi model stream) and tool steps; the result ends the wait.
 */
export async function ccNotes(b: ChiefBrainDO, token: string, body: { run?: unknown; events?: unknown; result?: unknown; net?: unknown; vm?: unknown }): Promise<{ status: number; json?: unknown }> {
  const run = typeof body.run === "string" ? body.run : ""
  const want = /^run_[0-9]{1,15}$/.test(run) ? cfgOf(b, `cc_token:${run}`) : undefined
  if (!want || !token || want !== (await sha(token)) || b.turnId !== run) return { status: 401 }
  // The Chief's `chief-net` (chief-turn-runner): kept for its next turns, and the script its machine applies now.
  if (body.net !== undefined) {
    const r = patchNet(readNet(cfgOf(b, "cc_net")), body.net)
    if (!r.ok) return { status: 400, json: { error: r.error } }
    writeConfig(b.sql, { cc_net: JSON.stringify(r.net) })
    return { status: 200, json: { net: r.net, script: netScript(r.net) } }
  }
  // The Chief's `chief-tools` (tools.ts): its own tools, kept per Chief for its next turns.
  const action = (body.vm as { action?: unknown } | null | undefined)?.action
  if (typeof action === "string" && action.startsWith("tools_")) return toolsOf(b.doEnv, b.config().agent!).ccTools(body.vm)
  // The Chief's `chief-wake` (wake.ts): a timer on this conversation that starts a turn later.
  if (typeof action === "string" && action.startsWith("wake_")) return wakeCall(b, b.turnConversation ?? "", body.vm)
  // The Chief's `chief-auto` (jobs.ts): its scheduled and triggered jobs, each run a turn of this conversation.
  if (typeof action === "string" && action.startsWith("auto_")) return autoCall(b, b.turnConversation ?? "", body.vm)
  // The Chief's `chief-github` (github.ts): its own GitHub login, kept per Chief.
  if (typeof action === "string" && action.startsWith("github_")) return githubOf(b.doEnv, b.config().agent!).ccGithub(b.config().agent!, body.vm, true)
  // The Chief's `chief-vm` (chief-turn-runner): its own sandbox VMs (sandbox.ts), kept per Chief in its `<agent>/sandboxes`
  // object (never per conversation), so its cap, identity and list are one; sandboxes this brain kept before move there.
  if (body.vm !== undefined) {
    const agent = b.config().agent!
    const legacy = legacyOf(b)
    const out = await sandboxesOf(b.doEnv, agent).ccSandboxCall(agent, body.vm, legacy)
    if (legacy.length) b.sql.exec(`DELETE FROM cb_config WHERE name = 'cc_sandboxes'`)
    return out
  }
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
        if (typeof e.delta === "string") [timing(b, run, "first_token"), ev({ type: e.type, delta: e.delta })]
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
