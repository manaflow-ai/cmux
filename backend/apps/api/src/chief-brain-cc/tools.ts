import type { Env } from "../env.ts"
import { GITHUB_CLIENT } from "./github.ts"
import { WAKE_CLIENT } from "./wake.ts"
import { AUTO_CLIENT } from "./jobs.ts"

/**
 * The Cloud Chief's own tools (Lawrence, 2026-10-22: "the Cloud Chief must be able to add or change its own
 * tools fast, with no snapshot rebake and no app update"): text files the Chief keeps through `chief-tools`
 * in its turn machine (POST 127.0.0.1:4018/vm {action: tools_list|tools_put|tools_rm}, chief-turn-runner passes it to
 * the Worker with the turn's token), and the Worker writes into every later turn machine with the rest of
 * its files (turn.ts `files`; chief-turn-runner writes them under /home/chief before Claude Code starts).
 *
 * Kept per Chief, not per conversation: in one object of the brain class named `<agent>/tools` (never a
 * conversation id), table cc_tools. The agent is the one the running turn's brain belongs to, so a Chief
 * reaches only its own tools. Only the tool folders below are writable: never ~/.config (the Mac gate, hub
 * and GitHub tokens), never ~/.claude/settings.json (the hook below) and never the client itself.
 */
export const TOOL_FILE_BYTES = 64_000
export const TOOL_TOTAL_BYTES = 256_000
export const TOOL_FILES = 100
const PATH = /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)*$/
const CLIENT = ".local/bin/chief-tools"
const GITHUB = ".local/bin/chief-github"
const WAKE = ".local/bin/chief-wake"
const AUTO = ".local/bin/chief-auto"
const SETTINGS = ".claude/settings.json"

/** A path the Chief may keep a tool at: ~/.local/bin/NAME, ~/.claude/agents/NAME, ~/.claude/skills/** or ~/.chief/tools/**. */
export const toolPathOk = (path: string): boolean => {
  if (path.length > 200 || !PATH.test(path) || path.split("/").some((p) => p === "." || p === "..") || path === CLIENT || path === GITHUB || path === WAKE || path === AUTO) return false
  const parts = path.split("/")
  if (path.startsWith(".local/bin/") || path.startsWith(".claude/agents/")) return parts.length === 3
  return (path.startsWith(".claude/skills/") || path.startsWith(".chief/tools/")) && parts.length >= 3
}

const enc = new TextEncoder()
const SCHEMA = `CREATE TABLE IF NOT EXISTS cc_tools (path TEXT PRIMARY KEY, text TEXT NOT NULL, bytes INTEGER NOT NULL, updated_at INTEGER NOT NULL)`
type Out = { status: number; json: unknown }

/** The tools object's side (ChiefBrainDO.ccTools): one call of `chief-tools`, already the Chief's own. */
export const toolsCall = (sql: SqlStorage, raw: unknown): Out => {
  sql.exec(SCHEMA)
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; path?: unknown; text?: unknown }
  const list = () => sql.exec<{ path: string; bytes: number; updated_at: number }>(`SELECT path, bytes, updated_at FROM cc_tools ORDER BY path`).toArray()
  if (req.action === "tools_list") {
    const tools = list()
    return { status: 200, json: { tools, bytes: tools.reduce((n, t) => n + t.bytes, 0), max_bytes: TOOL_TOTAL_BYTES, max_files: TOOL_FILES } }
  }
  const path = typeof req.path === "string" ? req.path : ""
  if (req.action === "tools_rm") {
    if (!list().some((t) => t.path === path)) return { status: 404, json: { error: `no tool at ${path || "(no path)"} (chief-tools ls)` } }
    sql.exec(`DELETE FROM cc_tools WHERE path = ?`, path)
    return { status: 200, json: { removed: path } }
  }
  if (req.action !== "tools_put") return { status: 400, json: { error: "action must be tools_list, tools_put or tools_rm" } }
  if (!toolPathOk(path)) return { status: 400, json: { error: "path must be .local/bin/NAME, .claude/agents/NAME, .claude/skills/... or .chief/tools/... (not .local/bin/chief-tools)" } }
  if (typeof req.text !== "string") return { status: 400, json: { error: "tools_put needs text" } }
  const bytes = enc.encode(req.text).length
  if (bytes > TOOL_FILE_BYTES) return { status: 413, json: { error: `a tool file is at most ${TOOL_FILE_BYTES} bytes (this one is ${bytes})` } }
  const others = list().filter((t) => t.path !== path)
  if (others.length + 1 > TOOL_FILES) return { status: 413, json: { error: `at most ${TOOL_FILES} tool files; remove one first (chief-tools rm PATH)` } }
  const total = others.reduce((n, t) => n + t.bytes, 0) + bytes
  if (total > TOOL_TOTAL_BYTES) return { status: 413, json: { error: `all tool files together are at most ${TOOL_TOTAL_BYTES} bytes (this would make ${total}); remove one first` } }
  sql.exec(`INSERT INTO cc_tools (path, text, bytes, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT (path) DO UPDATE SET text = excluded.text, bytes = excluded.bytes, updated_at = excluded.updated_at`, path, req.text, bytes, Date.now())
  return { status: 200, json: { path, bytes, total_bytes: total } }
}

/** Every tool as path -> text (still checked: a path rule tightened later drops a kept file). */
export const toolFiles = (sql: SqlStorage): Record<string, string> => {
  sql.exec(SCHEMA)
  const out: Record<string, string> = {}
  for (const t of sql.exec<{ path: string; text: string }>(`SELECT path, text FROM cc_tools`).toArray()) if (toolPathOk(t.path)) out[t.path] = t.text
  return out
}

type ToolsStub = { ccTools(req: unknown): Promise<Out>; ccToolFiles(): Promise<Record<string, string>> }
/** The Chief's tools object (`<agent>/tools`; a conversation id always starts with conv_). */
export const toolsOf = (env: Env, agent: string): ToolsStub => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`${agent}/tools`)) as unknown as ToolsStub

/**
 * Makes ~/.local/bin/* and ~/.chief/tools/** runnable when Claude Code starts (chief-turn-runner writes every file mode 600).
 * Shipped as a SessionStart hook so it works with the baked snapshot; chief-turn-runner does the same from the next bake.
 */
const CHMOD = "chmod 700 /home/chief/.local/bin/* 2>/dev/null; [ -d /home/chief/.chief/tools ] && find /home/chief/.chief/tools -type f -exec chmod 700 {} + 2>/dev/null; true"
const withHook = (raw: string | undefined): string => {
  let s: { hooks?: Record<string, Array<unknown>> } & Record<string, unknown> = {}
  try {
    const o = JSON.parse(raw ?? "{}") as unknown
    if (o && typeof o === "object" && !Array.isArray(o)) s = o as typeof s
  } catch {}
  const hooks = s.hooks && typeof s.hooks === "object" && !Array.isArray(s.hooks) ? s.hooks : {}
  const start = Array.isArray(hooks.SessionStart) ? hooks.SessionStart : []
  return JSON.stringify({ ...s, hooks: { ...hooks, SessionStart: [{ hooks: [{ type: "command", command: CHMOD }] }, ...start] } }, null, 2)
}

/**
 * `chief-tools`: the Chief's client (curl to chief-turn-runner on 127.0.0.1:4018; node only encodes the JSON). A put or rm
 * also changes the file in this machine at once, so the tool works in the same turn.
 */
const CLIENT_TEXT = `#!/bin/sh
# chief-tools: the Cloud Chief's own tools, kept by the Worker and written into every later turn machine
# (apps/api/src/chief-brain-cc/tools.ts). Paths are under your home: .local/bin/NAME (a command; made
# runnable), .claude/skills/NAME/SKILL.md (and its files), .claude/agents/NAME.md, .chief/tools/...
#   chief-tools ls
#   chief-tools put PATH FILE    (FILE - reads stdin)
#   chief-tools rm PATH
set -eu
usage() { echo "usage: chief-tools ls | put PATH FILE | rm PATH" >&2; exit 2; }
call() {
  out=$(curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-tools: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || { echo "chief-tools: $(printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).error??s)}catch{console.log(s)}})')" >&2; exit 1; }
  printf '%s\\n' "$body"
}
cmd="\${1:-ls}"
case "$cmd" in
  ls) printf '{"action":"tools_list"}' | call ;;
  put)
    [ $# -eq 3 ] || usage
    path="$2"; file="$3"
    tmp=$(mktemp)
    if [ "$file" = - ]; then cat > "$tmp"; else cat -- "$file" > "$tmp"; fi
    node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({action:"tools_put",path:process.argv[1],text:fs.readFileSync(process.argv[2],"utf8")}))' "$path" "$tmp" | call
    mkdir -p "$HOME/$(dirname -- "$path")"
    cp -- "$tmp" "$HOME/$path"
    rm -f -- "$tmp"
    case "$path" in .local/bin/*|.chief/tools/*) chmod 700 "$HOME/$path" ;; esac ;;
  rm)
    [ $# -eq 2 ] || usage
    node -e 'process.stdout.write(JSON.stringify({action:"tools_rm",path:process.argv[1]}))' "$2" | call
    rm -f -- "$HOME/$2" ;;
  *) usage ;;
esac
`

/**
 * A turn machine's files (turn.ts): CHIEF_CC_TURN_FILES (the tokens), then the Chief's tools (never on a token
 * path, toolPathOk), then the client and the settings with the hook, which no tool may replace.
 */
export const mergeTurnFiles = (base: Readonly<Record<string, string>>, tools: Readonly<Record<string, string>>): Record<string, string> => {
  const own = Object.fromEntries(Object.entries(tools).filter(([p]) => toolPathOk(p)))
  return { ...base, ...own, [CLIENT]: CLIENT_TEXT, [GITHUB]: GITHUB_CLIENT, [WAKE]: WAKE_CLIENT, [AUTO]: AUTO_CLIENT, [SETTINGS]: withHook(base[SETTINGS]) }
}
