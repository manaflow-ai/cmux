import type { Memory } from "../chief-brain/memory.ts"

/**
 * The memory tools on the Claude Code route (the Pi route's `zoom` and `date`, brain-tools.ts): `chief-memory zoom
 * ID N` and `chief-memory date ID` in a turn machine (POST 127.0.0.1:4018/vm {action: memory_zoom|memory_date},
 * chief-turn-runner forwards it with the turn's token) answer from this conversation brain's memory. Read only.
 */
type Out = { status: number; json: unknown }
const whole = (v: unknown, min: number) => (typeof v === "number" && Number.isInteger(v) && v >= min ? v : undefined)

/** One `chief-memory` call from the running turn. */
export const memoryCall = (memory: Memory, raw: unknown): Out => {
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; id?: unknown; n?: unknown }
  const id = whole(req.id, 0)
  if (req.action === "memory_zoom") {
    const n = whole(req.n ?? 1, 1)
    if (id === undefined || n === undefined) return { status: 400, json: { error: "memory_zoom needs id (a whole number) and n (1 or more)" } }
    return { status: 200, json: { text: memory.zoom(id, n) } }
  }
  if (req.action === "memory_date") {
    if (id === undefined) return { status: 400, json: { error: "memory_date needs id (a whole number)" } }
    return { status: 200, json: { text: memory.date(id, "UTC") } }
  }
  return { status: 400, json: { error: "action must be memory_zoom or memory_date" } }
}

/** `chief-memory`: the Chief's client (curl to chief-turn-runner on 127.0.0.1:4018). */
export const MEMORY_CLIENT = `#!/bin/sh
# chief-memory: open your memory tree (apps/api/src/chief-brain-cc/memory-tools.ts), as the view's zoom and date.
#   chief-memory zoom ID N     line ID+N of the view into its two halves; N=1 gives message ID in full
#   chief-memory date ID       the date and time (UTC) of message ID
set -eu
call() {
  out=$(curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-memory: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || { echo "chief-memory: $body" >&2; exit 1; }
  printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",(d)=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).text+"\\n"))'
}
case "\${1:-}" in
  zoom)
    [ $# -ge 2 ] || { echo 'usage: chief-memory zoom ID [N] | date ID' >&2; exit 2; }
    node -e 'process.stdout.write(JSON.stringify({action:"memory_zoom",id:Number(process.argv[1]),n:Number(process.argv[2]||1)}))' "$2" "\${3:-1}" | call ;;
  date)
    [ $# -eq 2 ] || { echo 'usage: chief-memory zoom ID [N] | date ID' >&2; exit 2; }
    node -e 'process.stdout.write(JSON.stringify({action:"memory_date",id:Number(process.argv[1])}))' "$2" | call ;;
  *) echo 'usage: chief-memory zoom ID [N] | date ID' >&2; exit 2 ;;
esac
`
