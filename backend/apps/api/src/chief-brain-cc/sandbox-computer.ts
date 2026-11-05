import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError } from "./vm.ts"
import { execAs } from "./sandbox-access.ts"
import { CUA_FALLBACK, DESKTOP_PRELUDE, DISPLAY, SCREEN, SETUP } from "./sandbox-computer-setup.ts"

export { SCREEN }

/**
 * The Chief's computer (cmux issue 31488): one of its own sandboxes (sandbox.ts) with a desktop, where it works
 * by sight (screenshot, click, type, keys, scroll, open a page), and whose screen its owner watches live in the
 * Chief's profile ("<name>'s Computer"). `chief-vm computer setup ID` gives a sandbox the desktop (Xvnc, a window
 * manager, Chrome, cua-driver and xdotool) and makes it the Chief's computer; one at a time, the newest setup wins.
 *
 * Safety:
 * - Every verb is on a sandbox that passed sandbox.ts's owner check, and runs through the Chief's own Freestyle
 *   identity (sandbox-access.ts): never the team key, never another Chief's VM.
 * - The desktop runs as the unprivileged `chief` user on the VM's own display :1 (Xvnc with RFB bound to loopback
 *   only, as the Cloud machines' devbox; sandbox-computer-setup.ts): nothing on the network can reach the screen. The owner sees it only through the Worker
 *   (`GET /v1/chiefs/<agent>/computer/screen`, chief-brain/routes.ts), which checks the owner first.
 * - Typed text and URLs reach the VM as environment values, never inside the command line; coordinates and key
 *   names are checked before they are used.
 * - The owner's view never wakes the computer: a paused one answers asleep (409). Nor does it keep one awake: after
 *   IDLE_MS without a Chief action the view shows the last frame instead of asking the VM, so an open profile does not
 *   hold off the sandbox's idle pause.
 */
export const COMPUTER_KEY = "cc_computer"
export const COMPUTER_USED_KEY = "cc_computer_used_at"
/** When the Chief last acted on its computer (ms), written only by the Chief's own verbs: `acting` in the owner's status. */
export const COMPUTER_ACTIVE_KEY = "cc_computer_active_at"
/** When the person last took over, drove or handed back the computer (ms): the lease's idle clock and the live view's. */
export const COMPUTER_HUMAN_KEY = "cc_computer_human_at"
/** A frame the owner's view may reuse instead of asking the VM again (several viewers, one shot). */
const SHOT_REUSE_MS = 700
/** No Chief action and no input from the person for this long: the owner's view stops asking the VM for frames. */
const IDLE_MS = 10 * 60_000
/** The Chief is using the computer now while its last action is this recent: each step is a click, a look, then the next (the chat's popup). */
const ACTING_MS = 45_000
const TEXT_MAX = 2000
const URL_MAX = 2000

export type Computer = { id: string; since: number }
type Out = { status: number; json: unknown }
type Req = Record<string, unknown>

const configValue = (b: ChiefBrainDO, name: string): string | undefined =>
  b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, name).toArray()[0]?.value

/** The sandbox that is the Chief's computer now, or null. */
export const computerOf = (b: ChiefBrainDO): Computer | null => {
  try {
    const c = JSON.parse(configValue(b, COMPUTER_KEY) ?? "null") as Computer | null
    return c && typeof c.id === "string" ? c : null
  } catch {
    return null
  }
}

/** When the Chief first set up a computer (ms), or null: it stays after the computer is gone, so the profile keeps its Computer section. */
export const computerUsedAt = (b: ChiefBrainDO): number | null => {
  const n = Number(configValue(b, COMPUTER_USED_KEY))
  return Number.isFinite(n) && n > 0 ? n : null
}

/** Whether the Chief acted on its computer moments ago. */
export const computerActing = (b: ChiefBrainDO, now = Date.now()): boolean => {
  const n = Number(configValue(b, COMPUTER_ACTIVE_KEY))
  return Number.isFinite(n) && now - n < ACTING_MS
}

const msOf = (b: ChiefBrainDO, key: string): number => {
  const n = Number(configValue(b, key))
  return Number.isFinite(n) && n > 0 ? n : 0
}
/** Whether neither the Chief nor the person used the computer within IDLE_MS (the owner's view refreshes only otherwise). */
export const computerIdle = (b: ChiefBrainDO, now = Date.now()): boolean => now - Math.max(msOf(b, COMPUTER_ACTIVE_KEY), msOf(b, COMPUTER_HUMAN_KEY)) >= IDLE_MS

/** The sandbox `id` is gone: when it was the computer, the Chief has none until the next setup. */
export const forgetComputer = (b: ChiefBrainDO, id?: string) => {
  const c = computerOf(b)
  if (c && (id === undefined || c.id === id)) b.sql.exec(`DELETE FROM cb_config WHERE name IN (?, ?, ?)`, COMPUTER_KEY, CONTROL_KEY, COMPUTER_HUMAN_KEY)
}

/** Base64 of a script, run by bash on the VM: no quoting of the script itself reaches a shell. */
const script = (text: string) => `printf %s '${btoa(String.fromCharCode(...new TextEncoder().encode(text)))}' | base64 -d | bash`

/** The screen as a JPEG in base64 (after the desktop is up). */
const SHOT = `/usr/local/bin/chief-desktop >/dev/null 2>&1; DISPLAY=${DISPLAY} import -silent -window root -quality 72 jpg:- | base64 -w0`

const int = (v: unknown, lo: number, hi: number): number | null => (typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi ? v : null)
const point = (req: Req, x = "x", y = "y"): [number, number] | string => {
  const px = int(req[x], 0, SCREEN.width - 1)
  const py = int(req[y], 0, SCREEN.height - 1)
  return px === null || py === null ? `${x} and ${y} must be whole numbers on the ${SCREEN.width}x${SCREEN.height} screen` : [px, py]
}
/** xdotool key names: letters, digits, + and _ (ctrl+l, Return, shift+Tab), space-separated. */
const KEYS = /^[A-Za-z0-9_+]{1,40}( [A-Za-z0-9_+]{1,40}){0,19}$/

/**
 * One cua-driver tool on the whole desktop, its JSON arguments in the environment; `fallback` (xdotool) only when
 * cua-driver ran nothing (missing, unreachable, or the tool or an argument unknown: CUA_FALLBACK). Any other cua-driver
 * error fails the verb as it is, so an action that partly ran is never repeated.
 */
const cuaOr = (n: number, tool: string, args: Record<string, unknown>, fallback: string) => ({
  line: `{ cua ${tool} "$CHIEF_CUA${n}"; c=$?; if [ $c -eq ${CUA_FALLBACK} ]; then ${fallback}; else [ $c -eq 0 ]; fi; }`,
  env: { [`CHIEF_CUA${n}`]: JSON.stringify({ scope: "desktop", ...args }) }
})

/**
 * The shell for one input verb (run as chief, with TEXT/URL/KEYS in the environment), or why not. Each verb goes
 * through cua-driver (DESKTOP_PRELUDE's `cua`), and through xdotool when cua-driver is missing or lacks the tool or
 * an argument (a double click, opening a page), never after a cua-driver error (cuaOr).
 */
export const inputCommand = (op: string, req: Req): { command: string; env?: Record<string, string> } | string => {
  const x = DESKTOP_PRELUDE
  const one = (tool: string, args: Record<string, unknown>, fallback: string, env: Record<string, string> = {}) => {
    const c = cuaOr(0, tool, args, fallback)
    return { command: `${x} ${c.line}`, env: { ...env, ...c.env } }
  }
  switch (op) {
    case "click": {
      const p = point(req)
      if (typeof p === "string") return p
      const name = req.button === undefined ? "left" : String(req.button)
      const button = ({ left: 1, middle: 2, right: 3 } as Record<string, number>)[name]
      if (!button) return "button must be left, middle or right"
      const count = req.count === undefined ? 1 : int(req.count, 1, 3)
      if (count === null) return "count must be 1, 2 or 3"
      const xdo = `xdotool mousemove --sync ${p[0]} ${p[1]} click --repeat ${count} --delay 80 ${button}`
      // A double or triple click is one gesture: xdotool times it; cua-driver has no click count.
      return count === 1 ? one("click", { x: p[0], y: p[1], button: name }, xdo) : { command: `${x} ${xdo}` }
    }
    case "move": {
      const p = point(req)
      return typeof p === "string" ? p : one("move_cursor", { x: p[0], y: p[1] }, `xdotool mousemove --sync ${p[0]} ${p[1]}`)
    }
    case "drag": {
      const a = point(req, "x", "y")
      const b = point(req, "to_x", "to_y")
      if (typeof a === "string") return a
      if (typeof b === "string") return b
      return one("drag", { from_x: a[0], from_y: a[1], to_x: b[0], to_y: b[1] }, `xdotool mousemove --sync ${a[0]} ${a[1]} mousedown 1 mousemove --sync ${b[0]} ${b[1]} mouseup 1`)
    }
    case "scroll": {
      const p = point(req)
      if (typeof p === "string") return p
      const direction = String(req.direction ?? "down")
      const dir = ({ up: 4, down: 5, left: 6, right: 7 } as Record<string, number>)[direction]
      if (!dir) return "direction must be up, down, left or right"
      const amount = req.amount === undefined ? 3 : int(req.amount, 1, 30)
      if (amount === null) return "amount must be 1 to 30"
      return one("scroll", { x: p[0], y: p[1], direction, amount, by: "line" }, `xdotool mousemove --sync ${p[0]} ${p[1]} click --repeat ${amount} --delay 30 ${dir}`)
    }
    case "type": {
      if (typeof req.text !== "string" || !req.text || req.text.length > TEXT_MAX) return `text must be 1 to ${TEXT_MAX} characters`
      return one("type_text", { text: req.text }, `xdotool type --delay 20 -- "$CHIEF_TEXT"`, { CHIEF_TEXT: req.text })
    }
    case "key": {
      if (typeof req.keys !== "string" || !KEYS.test(req.keys)) return "keys must be xdotool key names separated by spaces (ctrl+l, Return, shift+Tab)"
      // One press_key per checked name (xdotool-style names, as cua-driver takes them), each with its own fallback, in order.
      const steps = req.keys.split(" ").map((k, i) => cuaOr(i, "press_key", { key: k }, `xdotool key -- ${k}`))
      return { command: `${x} ${steps.map((s) => s.line).join(" && ")}`, env: Object.assign({}, ...steps.map((s) => s.env)) }
    }
    case "open": {
      const url = typeof req.url === "string" ? req.url : ""
      if (!/^https?:\/\/\S+$/.test(url) || url.length > URL_MAX) return "url must be an http or https address"
      return {
        // Done when a Chrome window shows (xdotool waits on X for it, bounded); otherwise the error is Chrome's own log.
        command:
          `${x} setsid nohup google-chrome --no-first-run --no-default-browser-check --disable-dev-shm-usage --start-maximized --user-data-dir=/home/chief/.chief-chrome -- "$CHIEF_URL" >>/tmp/chief-chrome.log 2>&1 < /dev/null &` +
          ` timeout 30 xdotool search --sync --onlyvisible --class google-chrome >/dev/null || { tail -c 1000 /tmp/chief-chrome.log >&2; exit 1; }`,
        env: { CHIEF_URL: url }
      }
    }
  }
  return `computer verb must be ${VERBS}`
}

const VERBS = "setup, screenshot, windows, click, move, drag, scroll, type, key, open, control, request_human or hand_back"
/** The desktop's windows: cua-driver's list_windows JSON, else one line per window from xdotool (id, pid, x y w h, title). */
const WINDOWS = `${DESKTOP_PRELUDE} cua list_windows '{}' && exit 0; echo '#xdotool'; for w in $(xdotool search --onlyvisible --name '.*' 2>/dev/null); do eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)"; printf '%s\\t%s\\t%s %s %s %s\\t%s\\n' "$w" "$(xdotool getwindowpid "$w" 2>/dev/null)" "$X" "$Y" "$WIDTH" "$HEIGHT" "$(xdotool getwindowname "$w" 2>/dev/null | tr '\\t\\n' '  ')"; done`
const windowsOf = (stdout: string): unknown => {
  const text = stdout.trim()
  if (!text.startsWith("#xdotool")) {
    try {
      const j = JSON.parse(text) as { windows?: unknown } | unknown[]
      return Array.isArray(j) ? j : ((j as { windows?: unknown }).windows ?? j)
    } catch {
      return text.slice(0, 20_000)
    }
  }
  return text.split("\n").slice(1).filter(Boolean).slice(0, 200).map((l) => {
    const [id, pid, geo, title] = l.split("\t")
    const [bx, by, bw, bh] = (geo ?? "").split(" ").map(Number)
    return { window_id: Number(id), pid: Number(pid) || null, title: title ?? "", bounds: { x: bx, y: by, width: bw, height: bh } }
  })
}

const shot = async (b: ChiefBrainDO, id: string): Promise<string> => {
  const r = await execAs(b, id, { command: SHOT, timeout_ms: 30_000, user: "chief" })
  const image = r.stdout.trim()
  // A whole JPEG only: base64 in full quads, starting with the JPEG marker (a cut-off stdout fails here).
  if (r.exit !== 0 || image.length % 4 !== 0 || !image.startsWith("/9j/") || !/^[A-Za-z0-9+/=]{100,}$/.test(image)) throw new CcError(`the screenshot failed${r.stderr ? `: ${r.stderr.slice(0, 200)}` : ""}`)
  return image
}

/**
 * Who drives the computer (the control lease, DESIGN "Control lease"): the Chief (the default) or its owner, who took
 * over in the profile's Computer tab (`by: "human"`), or whom the Chief asked to (`request_human`, `by: "chief"`, with
 * its reason). Kept in this object's cb_config under CONTROL_KEY and written only here. While the person holds it, the
 * Chief's input verbs, and exec, fs writes, stop, pause, delete and fork on this VM (sandbox.ts), are refused with
 * computer.human_has_control (it may still look: screenshot, windows, control). The hold ends when the person hands it
 * back, when the Chief hands back a hold it asked for itself (never a person's take-over), or by itself after
 * LEASE_IDLE_MS without the person's input (computed when read: no timer). After it ends, the Chief's next verb that
 * succeeds carries a note to look again first.
 *
 * The lease is checked when a Chief action starts: an action already running (a type of a long text, an exec) may
 * finish after the person takes over.
 */
export const CONTROL_KEY = "cc_computer_control"
export type Holder = "chief" | "human"
export type Control = { holder: Holder; since_ms: number; by?: Holder; reason?: string; expires_ms?: number }
type ControlRow = { holder: Holder; since_ms: number; by?: Holder; reason?: string; returned?: boolean }
/** A person's hold with no take-over or input for this long returns to the Chief. */
export const LEASE_IDLE_MS = 10 * 60_000
const REASON_MAX = 500
/** Verbs the Chief may run while the person holds the computer: they only look, or end a hold the Chief asked for. */
const LOOKS = new Set(["screenshot", "windows", "control", "request_human", "hand_back"])
export const HANDED_BACK_NOTE = "The person handed the computer back to you: the screen may have changed. Take a fresh screenshot before your next action."

const storedRow = (b: ChiefBrainDO): ControlRow => {
  try {
    const c = JSON.parse(configValue(b, CONTROL_KEY) ?? "null") as ControlRow | null
    if (c && (c.holder === "chief" || c.holder === "human") && typeof c.since_ms === "number") return c
  } catch {}
  return { holder: "chief", since_ms: computerOf(b)?.since ?? 0 }
}
/** When a person's hold ends by itself: LEASE_IDLE_MS after it began or after the person's last input, whichever is later. */
const leaseEnd = (b: ChiefBrainDO, c: ControlRow): number => Math.max(c.since_ms, msOf(b, COMPUTER_HUMAN_KEY)) + LEASE_IDLE_MS
/** The lease now: an idle person's hold reads as returned to the Chief from its end (written back on the next change). */
const controlRow = (b: ChiefBrainDO, now = Date.now()): ControlRow => {
  const c = storedRow(b)
  if (c.holder !== "human") return c
  const end = leaseEnd(b, c)
  return now >= end ? { holder: "chief", since_ms: end, returned: true } : c
}
/** The lease as clients see it: `by` and `expires_ms` while the person holds it. */
export const controlOf = (b: ChiefBrainDO, now = Date.now()): Control => {
  const c = controlRow(b, now)
  if (c.holder !== "human") return { holder: c.holder, since_ms: c.since_ms }
  return { holder: "human", since_ms: c.since_ms, by: c.by ?? "human", ...(c.reason ? { reason: c.reason } : {}), expires_ms: leaseEnd(b, c) }
}
const writeControl = (b: ChiefBrainDO, c: ControlRow) => writeConfig(b.sql, { [CONTROL_KEY]: JSON.stringify(c) })
/** The person did something with the computer: their hold's idle clock and the live view restart. */
const touchHuman = (b: ChiefBrainDO, now = Date.now()) => writeConfig(b.sql, { [COMPUTER_HUMAN_KEY]: String(now) })

/** The person takes the computer over, or hands it back to the Chief (the owner's route; idempotent). */
export const setControl = (b: ChiefBrainDO, action: "take_over" | "hand_back"): Control => {
  const now = Date.now()
  const cur = controlRow(b, now)
  if (action === "take_over") {
    // Taking over a hold the Chief asked for keeps its reason, and makes it the person's: the Chief can no longer end it.
    writeControl(b, cur.holder === "human" ? { holder: "human", since_ms: cur.since_ms, by: "human", ...(cur.reason ? { reason: cur.reason } : {}) } : { holder: "human", since_ms: now, by: "human" })
    touchHuman(b, now)
  } else if (cur.holder === "human") {
    writeControl(b, { holder: "chief", since_ms: now, returned: true })
    touchHuman(b, now)
  }
  return controlOf(b, now)
}
/** Whether the person holds the computer now. */
export const humanHasControl = (b: ChiefBrainDO): boolean => controlRow(b).holder === "human"
/** The person's input while they hold the computer (the owner's route): the hold stays theirs for LEASE_IDLE_MS more. */
export const humanInput = (b: ChiefBrainDO) => touchHuman(b)

/** The 409 for a Chief action on its computer while the person holds it. */
export const humanHasControlRefusal = (b: ChiefBrainDO, what = "your computer"): Out => {
  const c = controlOf(b)
  const ends = c.by === "chief" ? "wait until they are done, or chief-vm computer hand-back ID when you no longer need them" : "wait until they hand it back"
  return { status: 409, json: { code: "computer.human_has_control", error: `computer.human_has_control: the person is using ${what}${c.reason ? ` (you asked: ${c.reason})` : ""}; ${ends}. screenshot and windows still work`, control: c } }
}

/** One input verb on running sandbox `id` (the person's, through the owner's route; the Chief's, below). Writes no state. */
export const runInput = async (b: ChiefBrainDO, id: string, op: string, req: Req): Promise<Out> => {
  const input = inputCommand(op, req)
  if (typeof input === "string") return { status: 400, json: { error: input } }
  const r = await execAs(b, id, { command: input.command, timeout_ms: 30_000, user: "chief", ...(input.env ? { env: input.env } : {}) })
  if (r.exit !== 0) return { status: 502, json: { error: `${op} failed (exit ${r.exit})`, stderr: r.stderr.slice(-1000) } }
  return { status: 200, json: { done: op } }
}

/** One `chief-vm computer` verb on sandbox `id`, which passed the owner check (sandbox.ts). */
export const computerVerb = async (b: ChiefBrainDO, id: string, state: string, req: Req): Promise<Out> => {
  const op = String(req.op ?? "")
  if (state !== "running") return { status: 409, json: { error: `the sandbox is ${state}; chief-vm start ${id} first` } }
  const mine = computerOf(b)?.id === id
  // The lease is checked here, at the start of the action: one already running may finish after a take-over.
  // Setting up another computer would end the person's take-over: refused too.
  if ((mine || (op === "setup" && computerOf(b))) && humanHasControl(b) && !LOOKS.has(op)) return humanHasControlRefusal(b)
  if (op === "setup") {
    const r = await execAs(b, id, { command: script(SETUP), timeout_ms: 290_000, user: "root" })
    if (r.exit !== 0) return { status: 502, json: { error: `the desktop did not install (exit ${r.exit})`, stderr: r.stderr.slice(-2000) } }
    const now = Date.now()
    const driver = /driver cua-driver/.test(r.stdout) ? "cua-driver" : "xdotool"
    // A new computer starts with the Chief in control.
    writeConfig(b.sql, { [COMPUTER_KEY]: JSON.stringify({ id, since: now } satisfies Computer), [COMPUTER_ACTIVE_KEY]: String(now), [CONTROL_KEY]: JSON.stringify({ holder: "chief", since_ms: now } satisfies ControlRow), ...(computerUsedAt(b) ? {} : { [COMPUTER_USED_KEY]: String(now) }) })
    return { status: 200, json: { computer: id, screen: SCREEN, driver, image: await shot(b, id) } }
  }
  if (!mine) return { status: 409, json: { error: `${id} has no desktop; chief-vm computer setup ${id} first` } }
  if (op === "control") return { status: 200, json: { control: controlOf(b) } }
  if (op === "request_human") {
    const reason = typeof req.reason === "string" ? req.reason.trim() : ""
    if (!reason || reason.length > REASON_MAX) return { status: 400, json: { error: `request_human needs a reason (1 to ${REASON_MAX} characters): what the person should do` } }
    if (!humanHasControl(b)) writeControl(b, { holder: "human", since_ms: Date.now(), by: "chief", reason })
    return { status: 200, json: { control: controlOf(b) } }
  }
  if (op === "hand_back") {
    // Only a hold the Chief asked for (request_human) and the person did not take over: a take-over is the person's to end.
    const c = controlRow(b)
    if (c.holder === "human" && (c.by ?? "human") !== "chief") return humanHasControlRefusal(b)
    // The Chief ended its own request: nobody handed anything back, so no handed-back note follows.
    if (c.holder === "human") writeControl(b, { holder: "chief", since_ms: Date.now() })
    return { status: 200, json: { control: controlOf(b) } }
  }
  // The first verb that succeeds after the person handed the computer back says so once (a screenshot is that fresh
  // look, so it clears the note without carrying it); a verb that fails leaves it for the next.
  const row = controlRow(b)
  const note = row.returned && op !== "screenshot" ? { note: HANDED_BACK_NOTE } : {}
  const seen = () => {
    const now = controlRow(b)
    if (row.returned && now.returned && now.holder === "chief" && now.since_ms === row.since_ms) writeControl(b, { holder: "chief", since_ms: row.since_ms })
  }
  writeConfig(b.sql, { [COMPUTER_ACTIVE_KEY]: String(Date.now()) })
  if (op === "screenshot") {
    const image = await shot(b, id)
    seen()
    return { status: 200, json: { screen: SCREEN, image, ...note } }
  }
  if (op === "windows") {
    const r = await execAs(b, id, { command: WINDOWS, timeout_ms: 30_000, user: "chief" })
    if (r.exit !== 0) return { status: 502, json: { error: `windows failed (exit ${r.exit})`, stderr: r.stderr.slice(-1000) } }
    seen()
    return { status: 200, json: { windows: windowsOf(r.stdout), ...note } }
  }
  const done = await runInput(b, id, op, req)
  if (done.status !== 200) return done
  writeConfig(b.sql, { [COMPUTER_ACTIVE_KEY]: String(Date.now()) })
  seen()
  // The screen after the action (the Chief looks before its next step), unless it asked for none.
  return { status: 200, json: { done: op, screen: SCREEN, ...note, ...(req.shot === false ? {} : { image: await shot(b, id) }) } }
}

/**
 * The owner's view of the screen: one shot shared by viewers within SHOT_REUSE_MS, never more than one in flight.
 * While neither the Chief nor the person is using it (computerIdle), the last frame stays the answer, so watching does not
 * keep the VM busy.
 */
const recent = new WeakMap<object, { at: number; image: Promise<string>; id: string }>()
export const ownerShot = (b: ChiefBrainDO, id: string): Promise<string> => {
  const last = recent.get(b.sql)
  if (last && last.id === id && (Date.now() - last.at < SHOT_REUSE_MS || computerIdle(b))) return last.image
  const image = shot(b, id)
  const entry = { at: Date.now(), image, id }
  recent.set(b.sql, entry)
  image.catch(() => {
    if (recent.get(b.sql) === entry) recent.delete(b.sql)
  })
  return image
}
