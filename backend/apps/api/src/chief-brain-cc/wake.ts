import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"

/**
 * A Cloud Chief's own timers (Lawrence, 2026-10-24: "the Chief able to set a background timer so it wakes itself
 * and posts the new code in chat"): `chief-wake SECONDS "note"` in a turn machine (POST 127.0.0.1:4018/vm
 * {action: wake_set|wake_list|wake_clear}, chief-turn-runner forwards it with the turn's token) keeps a timer on
 * this conversation's brain; at its time a job queues "[wake] <note>" in the conversation's inbox, which starts a
 * turn as a message would (the local Chief's `sleep` tool, prompt.rs SLEEP_DESCRIPTION, on this route).
 *
 * Kept in table cc_wakes of the conversation brain; each timer is one Lifecycle job (`self-wake:<id>`), so it
 * survives eviction. A cleared timer's job finds no row and does nothing.
 */
export const WAKE_MAX_SECONDS = 86_400
export const WAKE_MAX = 20
const NOTE_MAX = 500
const SCHEMA = `CREATE TABLE IF NOT EXISTS cc_wakes (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, note TEXT NOT NULL, conversation TEXT NOT NULL)`
type Out = { status: number; json: unknown }

/** The shortest timer (30 s; CHIEF_CC_WAKE_MIN_SECONDS in tests). */
const minSeconds = (b: ChiefBrainDO) => {
  const v = Number(b.doEnv.CHIEF_CC_WAKE_MIN_SECONDS ?? 30)
  return Number.isFinite(v) && v >= 0 ? v : 30
}

const list = (b: ChiefBrainDO) => b.sql.exec<{ id: number; at: number; note: string }>(`SELECT id, at, note FROM cc_wakes ORDER BY at`).toArray()

/** One `chief-wake` call from the running turn of `conversation`. */
export const wakeCall = async (b: ChiefBrainDO, conversation: string, raw: unknown): Promise<Out> => {
  b.sql.exec(SCHEMA)
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; seconds?: unknown; note?: unknown }
  if (req.action === "wake_list") return { status: 200, json: { wakes: list(b) } }
  if (req.action === "wake_clear") {
    const n = list(b).length
    b.sql.exec(`DELETE FROM cc_wakes`)
    return { status: 200, json: { cleared: n } }
  }
  if (req.action !== "wake_set") return { status: 400, json: { error: "action must be wake_set, wake_list or wake_clear" } }
  const seconds = Number(req.seconds)
  const min = minSeconds(b)
  if (!Number.isFinite(seconds) || seconds < min || seconds > WAKE_MAX_SECONDS) return { status: 400, json: { error: `seconds must be ${min} to ${WAKE_MAX_SECONDS}` } }
  const note = typeof req.note === "string" ? req.note.trim().slice(0, NOTE_MAX) : ""
  if (!note) return { status: 400, json: { error: "a wake needs a note (what to do when it fires)" } }
  if (list(b).length >= WAKE_MAX) return { status: 413, json: { error: `at most ${WAKE_MAX} timers; clear them first (chief-wake clear)` } }
  const at = Date.now() + Math.round(seconds * 1000)
  const id = b.sql.exec<{ id: number }>(`INSERT INTO cc_wakes (at, note, conversation) VALUES (?, ?, ?) RETURNING id`, at, note, conversation).toArray()[0]!.id
  await b.schedule(`self-wake:${id}`, "self-wake", at)
  return { status: 200, json: { id, at, note } }
}

/** The `self-wake:<id>` job: queues the timer's note as a message of its conversation and starts a turn. */
export const wakeFire = async (b: ChiefBrainDO, jobId: string): Promise<void> => {
  b.sql.exec(SCHEMA)
  const id = Number(jobId.slice("self-wake:".length))
  const w = b.sql.exec<{ id: number; at: number; note: string; conversation: string }>(`SELECT id, at, note, conversation FROM cc_wakes WHERE id = ?`, id).toArray()[0]
  if (!w) return
  b.sql.exec(`DELETE FROM cc_wakes WHERE id = ?`, id)
  const cfg = b.config()
  if (!cfg.agent || !cfg.owner) return
  await b.lifecycle.start()
  const a = await b.admitted(cfg.agent, cfg.owner, false)
  if (!a.ok) return
  const seq = Number(b.sql.exec<{ seq: number }>(`SELECT seq FROM cb_cursor WHERE conversation = ?`, w.conversation).toArray()[0]?.seq ?? 0)
  const text = `[wake] ${w.note}\n(Your own timer, set with chief-wake; it is not the person's word.)`
  b.sql.exec(`INSERT INTO cb_inbox (message, conversation, seq, kind, thread_root, text, effect_authorized, woke) VALUES (?, ?, ?, 'chief', NULL, ?, 1, 1) ON CONFLICT (message) DO NOTHING`, `wake:${w.id}:${w.at}`, w.conversation, seq, text)
  b.kick()
}

/** `chief-wake`: the Chief's client (curl to chief-turn-runner on 127.0.0.1:4018). */
export const WAKE_CLIENT = `#!/bin/sh
# chief-wake: wake yourself later (apps/api/src/chief-brain-cc/wake.ts). At the time, "[wake] NOTE" starts a
# new turn of this conversation, as a message would. Use it instead of waiting or polling.
#   chief-wake SECONDS "note"     (30 to 86400)
#   chief-wake list
#   chief-wake clear              every pending timer
set -eu
call() {
  out=$(curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-wake: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || { echo "chief-wake: $body" >&2; exit 1; }
  printf '%s\\n' "$body"
}
case "\${1:-list}" in
  list) printf '{"action":"wake_list"}' | call ;;
  clear) printf '{"action":"wake_clear"}' | call ;;
  *)
    [ $# -eq 2 ] || { echo 'usage: chief-wake SECONDS "note" | list | clear' >&2; exit 2; }
    node -e 'process.stdout.write(JSON.stringify({action:"wake_set",seconds:Number(process.argv[1]),note:process.argv[2]}))' "$1" "$2" | call ;;
esac
`
