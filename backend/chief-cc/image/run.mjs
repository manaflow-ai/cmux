// One Cloud Chief turn in its VM (apps/api/src/chief-brain-cc/turn.ts starts it with start.sh).
// Runs as root: reads /run/chief/<run>.in (the Worker wrote it with exec stdin, mode 600), starts a
// fresh `claude -p` as the unprivileged `chief` user (stream-json, partial messages), and sends the
// model stream as events (text and thinking deltas, tool calls, one generation per model message) to
// the Worker in batches, then the result. The result also goes to /run/chief/<run>.out, which the Worker reads when a post is
// lost. The per-turn token never reaches the `chief` user: it stays in this process and in the
// root-only input file, which is removed at start.
import { spawn } from "node:child_process"
import { readFileSync, rmSync, writeFileSync, renameSync } from "node:fs"

const run = process.argv[2] ?? ""
if (!/^run_[0-9]{1,15}$/.test(run)) process.exit(2)
const dir = "/run/chief"
const input = JSON.parse(readFileSync(`${dir}/${run}.in`, "utf8"))
rmSync(`${dir}/${run}.in`, { force: true })
const { notes_url: notesUrl, token, prompt, system, model, max_ms: maxMs = 540_000 } = input
const t0 = Date.now()

let queue = []
let timer
let sending = Promise.resolve()
const post = (body) =>
  fetch(notesUrl, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) }).then(
    (r) => r.body?.cancel(),
    () => undefined
  )
const flush = () => {
  clearTimeout(timer)
  timer = undefined
  if (queue.length === 0) return sending
  const events = queue
  queue = []
  sending = sending.then(() => post({ run, events }))
  return sending
}
// One event of the model stream; `now` sends at once (a step boundary), else within 60 ms.
const note = (ev, now = false) => {
  queue.push(ev)
  if (now || queue.length >= 200) flush()
  else if (!timer) timer = setTimeout(flush, 60)
}

const env = {
  HOME: "/home/chief",
  PATH: "/opt/node/bin:/usr/local/bin:/usr/bin:/bin",
  LANG: "C.UTF-8",
  ANTHROPIC_BASE_URL: "http://127.0.0.1:4017",
  // The gateway authenticates the VM by its tailnet identity; Claude Code only needs a non-empty value.
  ANTHROPIC_AUTH_TOKEN: "subrouter",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  DISABLE_TELEMETRY: "1",
  DISABLE_ERROR_REPORTING: "1",
  DISABLE_AUTOUPDATER: "1",
  IS_SANDBOX: "1"
}
const args = ["-u", "chief", "--", "/usr/local/bin/claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--dangerously-skip-permissions", "--model", model, "--append-system-prompt", system]
// Its own process group, so the time limit stops Claude Code and everything it started, not only runuser.
const child = spawn("/usr/sbin/runuser", args, { cwd: "/home/chief/work", env, stdio: ["pipe", "pipe", "pipe"], detached: true })
child.stdin.end(prompt)
const kill = setTimeout(() => {
  try {
    process.kill(-child.pid, "SIGKILL")
  } catch {}
}, maxMs)

let firstToken = null
let result = null
let stderr = ""
let gen = -1
let lastGen = 0
const blocks = new Map()
let buf = ""
child.stderr.on("data", (d) => (stderr = (stderr + d).slice(-2000)))
child.stdout.on("data", (d) => {
  buf += d
  for (let i = buf.indexOf("\n"); i >= 0; i = buf.indexOf("\n")) {
    const line = buf.slice(0, i)
    buf = buf.slice(i + 1)
    let ev
    try {
      ev = JSON.parse(line)
    } catch {
      continue
    }
    onEvent(ev)
  }
})

// Claude Code's stream-json (with partial messages) as the Worker's events: one generation per model message.
function onEvent(ev) {
  if (ev.type === "result") return void (result = ev)
  if (ev.type === "user") {
    for (const c of ev.message?.content ?? []) if (c.type === "tool_result") note({ gen, type: "tool_done", id: String(c.tool_use_id), error: c.is_error === true })
    return
  }
  if (ev.type !== "stream_event") return
  const e = ev.event ?? {}
  if (e.type === "message_start") return void gen++
  if (e.type === "message_stop") return note({ gen, type: "done" }, true)
  const key = e.index
  if (e.type === "content_block_start") {
    const b = e.content_block ?? {}
    if (b.type === "text") [blocks.set(key, { kind: "text", text: "" }), note({ gen, type: "text_start" })]
    else if (b.type === "thinking") [blocks.set(key, { kind: "thinking", text: "" }), note({ gen, type: "thinking_start" })]
    else if (b.type === "tool_use") blocks.set(key, { kind: "tool", id: String(b.id), name: String(b.name), json: "" })
    return
  }
  const b = blocks.get(key)
  if (!b) return
  if (e.type === "content_block_delta") {
    const d = e.delta ?? {}
    if (d.type === "text_delta" && b.kind === "text") [(b.text += d.text), note({ gen, type: "text_delta", delta: d.text })]
    else if (d.type === "thinking_delta" && b.kind === "thinking") note({ gen, type: "thinking_delta", delta: d.thinking })
    else if (d.type === "input_json_delta" && b.kind === "tool") b.json += d.partial_json ?? ""
    else return
    if (firstToken === null) firstToken = Date.now() - t0
  } else if (e.type === "content_block_stop") {
    blocks.delete(key)
    if (b.kind === "text" && b.text.trim()) [(lastGen = gen), note({ gen, type: "text_done", text: b.text }, true)]
    if (b.kind === "tool") {
      let input = {}
      try {
        input = JSON.parse(b.json || "{}")
      } catch {}
      note({ gen, type: "tool", id: b.id, name: b.name, input }, true)
    }
  }
}

// A process Claude Code left behind may hold its output open: once runuser exits, the group goes too.
child.on("exit", () =>
  setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL")
    } catch {}
  }, 3_000).unref()
)
child.on("close", async (code) => {
  clearTimeout(kill)
  const ok = result !== null && result.is_error !== true && code === 0
  const u = result?.usage ?? {}
  const out = {
    run,
    status: ok ? "done" : "failed",
    reply: ok ? String(result.result ?? "") : "",
    error: ok ? undefined : String(result?.result ?? result?.subtype ?? `claude exited ${code}: ${stderr.slice(-300)}`).slice(0, 500),
    model,
    usage: { input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cache_read: u.cache_read_input_tokens ?? 0, cache_write: u.cache_creation_input_tokens ?? 0 },
    first_token_ms: firstToken,
    last_gen: lastGen,
    total_ms: Date.now() - t0
  }
  // The live events first, then the result file (the Worker may end the turn as soon as it reads it), then the result.
  await flush()
  writeFileSync(`${dir}/${run}.out.tmp`, JSON.stringify(out), { mode: 0o600 })
  renameSync(`${dir}/${run}.out.tmp`, `${dir}/${run}.out`)
  await post({ run, result: out })
  process.exit(0)
})
