#!/usr/bin/env bun
/**
 * O bench and conformance driver: a FAKE CP HOST (Chief Protocol v0) around a real opencode v2
 * server with the cmux-chief plugin, on a Freestyle VM (the container's stand-in). It does what
 * OpencodeBrainDO does: start the server, read its event stream, send `chief/wake`, answer the
 * brain's requests (initialize, conversation/read, conversation/post, chief/ack, chiefs/manage,
 * hands/list, hand/call), and measure what a member would see.
 *
 *   bun drive.ts <scenario.json> <out dir>
 *
 * Env: BENCH_KEY_FILE (gateway key, 0600, never printed), BENCH_GATEWAY (Anthropic Messages base URL
 * standing in for the host model gateway), BENCH_MODEL (default claude-opus-5-5), BENCH_EFFORT (low),
 * BENCH_MODEL_ID (the gateway's id for BENCH_MODEL).
 */
import { spawn, type ChildProcess } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const [scenarioPath, outDir] = process.argv.slice(2)
if (!scenarioPath || !outDir) throw new Error("usage: drive.ts <scenario.json> <out dir>")
mkdirSync(outDir, { recursive: true })
const scenario = JSON.parse(readFileSync(scenarioPath, "utf8")) as {
  name: string
  turns: Array<{ kind: string; gap: number; text: string }>
  crash?: { text: string; kill_after_ms: number }
}
const MODEL = process.env.BENCH_MODEL || "claude-opus-5-5"
const EFFORT = process.env.BENCH_EFFORT || "low"
const PORT = 4096
const HOST_PORT = 4100
const PASSWORD = crypto.randomUUID()
const AUTH = `Basic ${btoa(`opencode:${PASSWORD}`)}`
const BASE = `http://127.0.0.1:${PORT}`
// A configured plugin is a directory; opencode loads its `server` entry (plugin/server.ts).
const PLUGIN = join(import.meta.dir, "..", "plugin")
const KEY = readFileSync(process.env.BENCH_KEY_FILE || "/root/.cmux-bench/provider.key", "utf8").trim()
const CHIEF_DIR = "/tmp/chief"
mkdirSync(CHIEF_DIR, { recursive: true })

const log = (o: Record<string, unknown>) => {
  const line = JSON.stringify({ at: Date.now(), ...o })
  console.log(line)
  appendFileSync(join(outDir, "events.jsonl"), line + "\n")
}

// ------------------------------------------------------------ the fake host
const CONV = "conv_BENCH0000000000000000000000"
type Msg = { id: string; seq: number; author: { id: string; name: string; kind: string }; text: string }
const messages: Array<Msg> = []
const posts = new Map<string, { message: string; tries: number }>()
let ackedCursor = 0
const acks: Array<Record<string, unknown>> = []
const hostCalls: Array<string> = []

const addMessage = (author: Msg["author"], text: string) => {
  const seq = messages.length + 1
  const m = { id: `msg_${seq}`, seq, author, text }
  messages.push(m)
  return m
}

const hostMethods: Record<string, (p: Record<string, unknown>) => unknown> = {
  initialize: () => ({ protocol: 1, chief: { id: "agent_BENCH", name: "Bench Chief", owner: "user_bench", role: "Chief of staff", personality: "", instructions: "", model: MODEL, effort: EFFORT }, grants: ["chiefs"], capabilities: { hands: true, chiefs: true, model_gateway: true } }),
  "conversation/read": (p) => {
    const after = Number(p.after ?? 0)
    const limit = Number(p.limit ?? 50)
    const rows = messages.filter((m) => m.seq > after).slice(-limit).map((m) => ({ ...m, author: m.author.id === "agent_BENCH" ? { ...m.author, kind: "self" } : m.author }))
    return { conversation: { id: CONV, kind: "chief", title: "Bench" }, messages: rows, cursor: messages.length }
  },
  "conversation/post": (p) => {
    const key = String(p.client_msg_id)
    const had = posts.get(key)
    if (had) {
      had.tries += 1
      return { message: had.message, replayed: true }
    }
    const m = addMessage({ id: "agent_BENCH", name: "Bench Chief", kind: "agent" }, String(p.body))
    posts.set(key, { message: m.id, tries: 1 })
    return { message: m.id }
  },
  "chief/ack": (p) => {
    acks.push(p)
    ackedCursor = Math.max(ackedCursor, Number(p.cursor ?? 0))
    return {}
  },
  "chiefs/manage": (p) => (p.action === "list" ? [{ id: "agent_BENCH", display_name: "Bench Chief", is_default: true }] : `chiefs ${String(p.action)}: refused in the bench`),
  "hands/list": () => [],
  "hand/call": () => {
    throw new Error("no hand is paired")
  }
}

Bun.serve({
  hostname: "127.0.0.1",
  port: HOST_PORT,
  async fetch(req) {
    if (req.headers.get("authorization") !== `Bearer ${KEY}`) return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32001, message: "bad chief token" } }, { status: 401 })
    const body = (await req.json()) as { id: number; method: string; params: Record<string, unknown> }
    hostCalls.push(body.method)
    const fn = hostMethods[body.method]
    if (!fn) return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32601, message: `unknown method ${body.method}` } })
    try {
      return Response.json({ jsonrpc: "2.0", id: body.id, result: fn(body.params ?? {}) })
    } catch (e) {
      return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: e instanceof Error ? e.message : String(e) } })
    }
  }
})

// ------------------------------------------------------------ the brain's server
let server: ChildProcess | undefined
let life = 0
process.on("exit", () => server?.kill("SIGKILL"))

const startServer = async (): Promise<{ spawn_ms: number; ready_ms: number; plugin_ms: number }> => {
  life += 1
  const data = `/tmp/oc-data-${life}` // a new container has an empty disk
  rmSync(data, { recursive: true, force: true })
  mkdirSync(data, { recursive: true })
  const config = {
    $schema: "https://opencode.ai/config.json",
    plugins: [
      {
        package: PLUGIN,
        options: {
          host: `http://127.0.0.1:${HOST_PORT}/cp`,
          gateway: process.env.BENCH_GATEWAY || "https://openrouter.ai/api/v1",
          tokenEnv: "CMUX_CHIEF_TOKEN",
          modelIds: { "claude-opus-5-5": process.env.BENCH_MODEL_ID || "anthropic/claude-opus-5.5", "claude-sonnet-5-5": "anthropic/claude-sonnet-5.5", "claude-haiku-5-5": "anthropic/claude-haiku-5.5" },
          cacheTtl: "1h",
          traceRequests: join(outDir, "requests.jsonl")
        }
      }
    ]
  }
  const t0 = performance.now()
  server = spawn(process.env.OPENCODE_BIN || "opencode", ["serve", "--hostname", "127.0.0.1", "--port", String(PORT)], {
    cwd: CHIEF_DIR,
    env: {
      ...process.env,
      OPENCODE_SERVER_PASSWORD: PASSWORD,
      OPENCODE_CONFIG_CONTENT: JSON.stringify(config),
      OPENCODE_DISABLE_PROJECT_CONFIG: "1",
      XDG_DATA_HOME: data,
      XDG_STATE_HOME: data,
      XDG_CACHE_HOME: `${data}/cache`,
      CMUX_CHIEF_TOKEN: KEY
    },
    stdio: ["ignore", "pipe", "pipe"]
  })
  const serverLog = join(outDir, `server-${life}.log`)
  server.stdout?.on("data", (b) => appendFileSync(serverLog, b))
  server.stderr?.on("data", (b) => appendFileSync(serverLog, b))
  const spawn_ms = performance.now() - t0
  // Readiness: the API answers, then the plugin's RPC answers. Bounded probe (the DO does the same).
  let ready_ms = -1
  let plugin_ms = -1
  let last = ""
  for (let i = 0; i < 600; i++) {
    const ok = await fetch(`${BASE}/api/info`, { headers: { authorization: AUTH } }).then((r) => r.ok, () => false)
    if (ok) {
      if (ready_ms < 0) ready_ms = performance.now() - t0
      last = await rpc("status", { run: "probe" }).then(() => "", (e) => String(e))
      if (!last) {
        plugin_ms = performance.now() - t0
        break
      }
    }
    await Bun.sleep(100)
  }
  if (plugin_ms < 0) throw new Error(`server ${life} not ready (${last}); see ${serverLog}`)
  return { spawn_ms, ready_ms, plugin_ms }
}

const rpc = async (method: string, input: unknown): Promise<unknown> => {
  const r = await fetch(`${BASE}/api/rpc/cmux-chief/${method}`, { method: "POST", headers: { authorization: AUTH, "content-type": "application/json" }, body: JSON.stringify({ input }) })
  const text = await r.text()
  if (!r.ok) throw new Error(`rpc ${method} ${r.status}: ${text.slice(0, 400)}`)
  return (JSON.parse(text) as { output?: unknown }).output
}

// ------------------------------------------------------------ brain -> host notifications (event stream)
type Note = { jsonrpc: "2.0"; method: string; params: Record<string, unknown> & { run: unknown; seq: number } }
const listeners = new Set<(n: Note, at: number) => void>()
let streamAbort: AbortController | undefined

const openStream = async () => {
  streamAbort?.abort()
  const ac = new AbortController()
  streamAbort = ac
  const res = await fetch(`${BASE}/api/event`, { headers: { authorization: AUTH, accept: "text/event-stream" }, signal: ac.signal })
  if (!res.ok || !res.body) throw new Error(`event stream ${res.status}`)
  const reader = res.body.getReader()
  const dec = new TextDecoder()
  let buf = ""
  let connected!: () => void
  const ready = new Promise<void>((r) => (connected = r))
  void (async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        buf += dec.decode(value, { stream: true })
        let i: number
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const frame = buf.slice(0, i)
          buf = buf.slice(i + 2)
          const data = frame.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trimStart()).join("\n")
          if (!data) continue
          let ev: { type?: string; data?: unknown }
          try {
            ev = JSON.parse(data)
          } catch {
            continue
          }
          if (ev.type === "server.connected") connected()
          if (ev.type === "rpc.cmux-chief.cp") {
            const at = performance.now()
            for (const l of listeners) l(ev.data as Note, at)
          }
        }
      }
    } catch {
      /* aborted or the server died */
    }
  })()
  await ready
}

// ------------------------------------------------------------ one turn
interface TurnResult {
  i: number
  kind: string
  run: string
  ok: boolean
  wake_ms: number
  first_token_ms: number | null
  first_text_ms: number | null
  /** First token or first tool step: the first thing a member sees move (the activity line aside). */
  first_visible_ms: number | null
  turn_ms: number | null
  reply: string | null
  deltas: number
  activity: Array<string>
  steps: Array<string>
  run_end: Record<string, unknown> | null
}

const runTurn = async (i: number, kind: string, text: string | null, opts: { killAfterMs?: number } = {}): Promise<TurnResult> => {
  const wake_id = `w${i}`
  const run = `run_${wake_id}`
  const r: TurnResult = { i, kind, run, ok: false, wake_ms: 0, first_token_ms: null, first_text_ms: null, first_visible_ms: null, turn_ms: null, reply: null, deltas: 0, activity: [], steps: [], run_end: null }
  let t0 = 0
  let ended!: (v: boolean) => void
  const done = new Promise<boolean>((res) => (ended = res))
  const onNote = (n: Note, at: number) => {
    if (n.params.run !== run && (n.params.run as { id?: string } | undefined)?.id !== run) return
    const p = n.params
    if (n.method === "run/delta") {
      r.deltas += 1
      if (r.first_token_ms === null) r.first_token_ms = at - t0
      if (r.first_visible_ms === null) r.first_visible_ms = at - t0
      if (r.first_text_ms === null && p.kind === "talk") r.first_text_ms = at - t0
    } else if (n.method === "run/activity") r.activity.push(String(p.line))
    else if (n.method === "run/step") {
      if (r.first_visible_ms === null) r.first_visible_ms = at - t0
      const st = p.step as { kind: string; tool?: { name?: string } }
      r.steps.push(`${st.kind}:${st.tool?.name ?? ""}`)
    } else if (n.method === "run/end") {
      r.run_end = p.run as Record<string, unknown>
      r.turn_ms = at - t0
      ended(true)
    }
  }
  listeners.add(onNote)
  if (text !== null) addMessage({ id: "user_bench", name: "Lawrence", kind: "person" }, text)
  t0 = performance.now()
  await rpc("wake", { wake_id, conversation: CONV, cursor: ackedCursor, reason: "dm" })
  r.wake_ms = performance.now() - t0
  if (opts.killAfterMs !== undefined) {
    const tk = performance.now()
    while (r.first_token_ms === null && performance.now() - tk < 60_000) await Bun.sleep(50)
    await Bun.sleep(opts.killAfterMs)
    listeners.delete(onNote)
    return r
  }
  const timeout = new Promise<boolean>((res) => setTimeout(() => res(false), 240_000))
  r.ok = await Promise.race([done, timeout])
  listeners.delete(onNote)
  const posted = posts.get(`chief-reply:${run}`)
  r.reply = posted ? (messages.find((m) => m.id === posted.message)?.text ?? null) : null
  return r
}

// ------------------------------------------------------------ the scenario
const out = (name: string, v: unknown) => writeFileSync(join(outDir, name), JSON.stringify(v, null, 2))
const turns: Array<TurnResult & { gap: number }> = []
const cold = await startServer()
log({ msg: "server", life, ...cold })
await openStream()

for (const [n, t] of scenario.turns.entries()) {
  if (t.gap > 0) await Bun.sleep(t.gap * 1000)
  const res = await runTurn(n + 1, t.kind, t.text)
  turns.push({ ...res, gap: t.gap })
  log({ msg: "turn", ...res })
}

// Crash mid-turn: kill the server after the first token, start a new one (empty disk: a new
// container), send the same wake again. The reply must be posted exactly once (client_msg_id).
let crash: Record<string, unknown> | null = null
if (scenario.crash) {
  const n = scenario.turns.length + 1
  const first = await runTurn(n, "crash", scenario.crash.text, { killAfterMs: scenario.crash.kill_after_ms })
  const tKill = performance.now()
  server?.kill("SIGKILL")
  streamAbort?.abort()
  const restart = await startServer()
  await openStream()
  const status = await rpc("status", { run: `run_w${n}` }).catch((e) => String(e))
  const again = await runTurn(n, "crash-resume", null)
  const post = posts.get(`chief-reply:run_w${n}`)
  crash = {
    first_token_ms_before_kill: first.first_token_ms,
    deltas_before_kill: first.deltas,
    restart,
    status_after_restart: status,
    resume: again,
    kill_to_reply_ms: again.turn_ms === null ? null : performance.now() - tKill,
    posts_for_run: post ? 1 : 0,
    post_tries_for_run: post?.tries ?? 0
  }
  log({ msg: "crash", ...crash })
}

out("summary.json", { scenario: scenario.name, model: MODEL, effort: EFFORT, cold, turns, crash, acks, host_calls: hostCalls.reduce<Record<string, number>>((a, m) => ((a[m] = (a[m] ?? 0) + 1), a), {}) })
server?.kill("SIGKILL")
streamAbort?.abort()
process.exit(0)
