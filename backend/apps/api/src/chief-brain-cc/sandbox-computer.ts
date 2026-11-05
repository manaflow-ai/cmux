import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError } from "./vm.ts"
import { execAs } from "./sandbox-access.ts"

/**
 * The Chief's computer (cmux issue 31488): one of its own sandboxes (sandbox.ts) with a desktop, where it works
 * by sight (screenshot, click, type, keys, scroll, open a page), and whose screen its owner watches live in the
 * Chief's profile ("<name>'s Computer"). `chief-vm computer setup ID` gives a sandbox the desktop (Xvfb, a window
 * manager, Chrome, xdotool) and makes it the Chief's computer; one at a time, the newest setup wins.
 *
 * Safety:
 * - Every verb is on a sandbox that passed sandbox.ts's owner check, and runs through the Chief's own Freestyle
 *   identity (sandbox-access.ts): never the team key, never another Chief's VM.
 * - The desktop runs as the unprivileged `chief` user, only on the VM's own display :1 (no TCP listener, no VNC
 *   port): nothing on the network can reach the screen. The owner sees it only through the Worker
 *   (`GET /v1/chiefs/<agent>/computer/screen`, chief-brain/routes.ts), which checks the owner first.
 * - Typed text and URLs reach the VM as environment values, never inside the command line; coordinates and key
 *   names are checked before they are used.
 * - The owner's view never wakes the computer: a paused one answers asleep (409). Nor does it keep one awake: after
 *   IDLE_MS without a Chief action the view shows the last frame instead of asking the VM, so an open profile does not
 *   hold off the sandbox's idle pause.
 */
export const COMPUTER_KEY = "cc_computer"
export const COMPUTER_USED_KEY = "cc_computer_used_at"
/** When the Chief last acted on its computer (ms): the owner's live view follows only recent work. */
export const COMPUTER_ACTIVE_KEY = "cc_computer_active_at"
export const SCREEN = { width: 1280, height: 800 }
const DISPLAY = ":1"
/** A frame the owner's view may reuse instead of asking the VM again (several viewers, one shot). */
const SHOT_REUSE_MS = 700
/** No Chief action for this long: the owner's view stops asking the VM for frames. */
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

/** Whether the Chief acted on its computer within IDLE_MS (the owner's view refreshes only then). */
export const computerIdle = (b: ChiefBrainDO, now = Date.now()): boolean => {
  const n = Number(configValue(b, COMPUTER_ACTIVE_KEY))
  return !(Number.isFinite(n) && now - n < IDLE_MS)
}

/** The sandbox `id` is gone: when it was the computer, the Chief has none until the next setup. */
export const forgetComputer = (b: ChiefBrainDO, id?: string) => {
  const c = computerOf(b)
  if (c && (id === undefined || c.id === id)) b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, COMPUTER_KEY)
}

/** Base64 of a script, run by bash on the VM: no quoting of the script itself reaches a shell. */
const script = (text: string) => `printf %s '${btoa(String.fromCharCode(...new TextEncoder().encode(text)))}' | base64 -d | bash`

/** Installs the desktop and the helpers (root, once; a second setup only checks). */
const SETUP = `set -e
export DEBIAN_FRONTEND=noninteractive
id chief >/dev/null 2>&1 || useradd -m -s /bin/bash chief
need=""
for c in Xvfb xdotool fluxbox import xdpyinfo xsetroot; do command -v "$c" >/dev/null 2>&1 || need=1; done
if [ -n "$need" ]; then
  # A fresh VM's unattended upgrades can hold the dpkg lock for a few minutes: wait for it, don't fail.
  apt-get -o DPkg::Lock::Timeout=120 update -qq
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends xvfb xdotool fluxbox imagemagick x11-utils x11-xserver-utils fonts-dejavu-core fonts-noto-color-emoji wget ca-certificates >/dev/null
fi
if ! command -v google-chrome >/dev/null 2>&1; then
  wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq /tmp/chrome.deb >/dev/null
  rm -f /tmp/chrome.deb
fi
cat > /usr/local/bin/chief-desktop <<'EOF'
#!/bin/bash
# Starts the Chief's desktop on display ${DISPLAY} when it is not running (after a boot or a stop). Runs as chief.
export DISPLAY=${DISPLAY}
if ! xdpyinfo >/dev/null 2>&1; then
  setsid nohup Xvfb ${DISPLAY} -screen 0 ${SCREEN.width}x${SCREEN.height}x24 -nolisten tcp >/tmp/chief-xvfb.log 2>&1 < /dev/null &
  for _ in $(seq 100); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.05; done
fi
pgrep -u "$(id -u)" -x fluxbox >/dev/null || setsid nohup fluxbox >/tmp/chief-fluxbox.log 2>&1 < /dev/null &
xsetroot -solid '#1d1f24' 2>/dev/null || true
EOF
chmod 755 /usr/local/bin/chief-desktop
su - chief -c /usr/local/bin/chief-desktop
su - chief -c 'DISPLAY=${DISPLAY} xdpyinfo' >/dev/null
echo ready`

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

/** The shell for one input verb (run as chief, with TEXT/URL/KEYS in the environment), or why not. */
export const inputCommand = (op: string, req: Req): { command: string; env?: Record<string, string> } | string => {
  const x = `export DISPLAY=${DISPLAY}; /usr/local/bin/chief-desktop >/dev/null 2>&1;`
  switch (op) {
    case "click": {
      const p = point(req)
      if (typeof p === "string") return p
      const button = req.button === undefined ? 1 : ({ left: 1, middle: 2, right: 3 } as Record<string, number>)[String(req.button)]
      if (!button) return "button must be left, middle or right"
      const count = req.count === undefined ? 1 : int(req.count, 1, 3)
      if (count === null) return "count must be 1, 2 or 3"
      return { command: `${x} xdotool mousemove --sync ${p[0]} ${p[1]} click --repeat ${count} --delay 80 ${button}` }
    }
    case "move": {
      const p = point(req)
      return typeof p === "string" ? p : { command: `${x} xdotool mousemove --sync ${p[0]} ${p[1]}` }
    }
    case "drag": {
      const a = point(req, "x", "y")
      const b = point(req, "to_x", "to_y")
      if (typeof a === "string") return a
      if (typeof b === "string") return b
      return { command: `${x} xdotool mousemove --sync ${a[0]} ${a[1]} mousedown 1 mousemove --sync ${b[0]} ${b[1]} mouseup 1` }
    }
    case "scroll": {
      const p = point(req)
      if (typeof p === "string") return p
      const dir = ({ up: 4, down: 5, left: 6, right: 7 } as Record<string, number>)[String(req.direction ?? "down")]
      if (!dir) return "direction must be up, down, left or right"
      const amount = req.amount === undefined ? 3 : int(req.amount, 1, 30)
      if (amount === null) return "amount must be 1 to 30"
      return { command: `${x} xdotool mousemove --sync ${p[0]} ${p[1]} click --repeat ${amount} --delay 30 ${dir}` }
    }
    case "type": {
      if (typeof req.text !== "string" || !req.text || req.text.length > TEXT_MAX) return `text must be 1 to ${TEXT_MAX} characters`
      return { command: `${x} xdotool type --delay 20 -- "$CHIEF_TEXT"`, env: { CHIEF_TEXT: req.text } }
    }
    case "key": {
      if (typeof req.keys !== "string" || !KEYS.test(req.keys)) return "keys must be xdotool key names separated by spaces (ctrl+l, Return, shift+Tab)"
      // Unquoted on purpose: each checked name is its own argument.
      return { command: `${x} xdotool key --delay 40 -- $CHIEF_KEYS`, env: { CHIEF_KEYS: req.keys } }
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
  return "computer verb must be setup, screenshot, click, move, drag, scroll, type, key or open"
}

const shot = async (b: ChiefBrainDO, id: string): Promise<string> => {
  const r = await execAs(b, id, { command: SHOT, timeout_ms: 30_000, user: "chief" })
  const image = r.stdout.trim()
  // A whole JPEG only: base64 in full quads, starting with the JPEG marker (a cut-off stdout fails here).
  if (r.exit !== 0 || image.length % 4 !== 0 || !image.startsWith("/9j/") || !/^[A-Za-z0-9+/=]{100,}$/.test(image)) throw new CcError(`the screenshot failed${r.stderr ? `: ${r.stderr.slice(0, 200)}` : ""}`)
  return image
}

/** One `chief-vm computer` verb on sandbox `id`, which passed the owner check (sandbox.ts). */
export const computerVerb = async (b: ChiefBrainDO, id: string, state: string, req: Req): Promise<Out> => {
  const op = String(req.op ?? "")
  if (state !== "running") return { status: 409, json: { error: `the sandbox is ${state}; chief-vm start ${id} first` } }
  if (op === "setup") {
    const r = await execAs(b, id, { command: script(SETUP), timeout_ms: 290_000, user: "root" })
    if (r.exit !== 0) return { status: 502, json: { error: `the desktop did not install (exit ${r.exit})`, stderr: r.stderr.slice(-2000) } }
    const now = Date.now()
    writeConfig(b.sql, { [COMPUTER_KEY]: JSON.stringify({ id, since: now } satisfies Computer), [COMPUTER_ACTIVE_KEY]: String(now), ...(computerUsedAt(b) ? {} : { [COMPUTER_USED_KEY]: String(now) }) })
    return { status: 200, json: { computer: id, screen: SCREEN, image: await shot(b, id) } }
  }
  if (computerOf(b)?.id !== id) return { status: 409, json: { error: `${id} has no desktop; chief-vm computer setup ${id} first` } }
  writeConfig(b.sql, { [COMPUTER_ACTIVE_KEY]: String(Date.now()) })
  if (op === "screenshot") return { status: 200, json: { screen: SCREEN, image: await shot(b, id) } }
  const input = inputCommand(op, req)
  if (typeof input === "string") return { status: 400, json: { error: input } }
  const r = await execAs(b, id, { command: input.command, timeout_ms: 30_000, user: "chief", ...(input.env ? { env: input.env } : {}) })
  if (r.exit !== 0) return { status: 502, json: { error: `${op} failed (exit ${r.exit})`, stderr: r.stderr.slice(-1000) } }
  // The screen after the action (the Chief looks before its next step), unless it asked for none.
  return { status: 200, json: { done: op, screen: SCREEN, ...(req.shot === false ? {} : { image: await shot(b, id) }) } }
}

/**
 * The owner's view of the screen: one shot shared by viewers within SHOT_REUSE_MS, never more than one in flight.
 * While the Chief is idle (computerIdle), the last frame stays the answer, so watching does not keep the VM busy.
 */
const recent = new WeakMap<object, { at: number; image: Promise<string>; id: string }>()
/** While the Chief is idle (computerIdle), the last frame of `id`: the owner's view shows it without a VM lookup. */
export const idleShot = (b: ChiefBrainDO, id: string): Promise<string> | null => {
  const last = recent.get(b.sql)
  return last && last.id === id && computerIdle(b) ? last.image : null
}
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
