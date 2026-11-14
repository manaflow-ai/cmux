import { ALIVE_WITHIN_MS, duration, LIMITS, THREAD_WINDOW_MS, type DeskState, type MacCheck, type SlackAction } from "./connectivity-alerts.ts"

/**
 * The connectivity alerts' own watch (PROTOCOL.md "Connectivity canary" and "Connectivity heartbeat"):
 *
 * - A synthetic canary (cmux-mobile-canary on an always-on fleet Mac) dials a test Mac every minute through
 *   the real path, over each transport, and reports each run. Three failures in a row at the same step post
 *   one team incident; the first pass edits it to resolved. So an outage nobody is using the app through is
 *   still heard. A failure at the Mac's end while that Mac is not pinging the service is the canary's own
 *   host being down, said as such and never as a service outage.
 * - The alerting watches itself: a canary that stops reporting for 10 minutes, or no team phone checking in
 *   for 4 hours of working time (weekdays 9:00-19:00 Pacific), posts "alerting is blind" once, so silence in
 *   the channel never passes for health.
 */

/** Where a canary run stopped. */
export type CanaryStep = "auth" | "ice" | "register" | "signaling" | "presence" | "dial" | "ping"
const STEPS = new Set<CanaryStep>(["auth", "ice", "register", "signaling", "presence", "dial", "ping"])
/** Steps that need nothing from the canary's Mac: a failure there is always the service (or the network to it). */
const SERVICE_STEPS = new Set<CanaryStep>(["auth", "ice", "register", "signaling"])

export interface CanaryResult {
  /** The probe: one transport and forced path (`wireguard`, `wireguard-turn-tls`, `webrtc`, `webrtc-relay`). */
  readonly probe: string
  readonly at: string
  readonly outcome: "pass" | "fail"
  readonly step?: CanaryStep
  readonly error?: string
  readonly transport?: string
  readonly path?: string
  readonly durationMs: number
  readonly mac: { readonly id: string; readonly name: string }
}

export class CanaryError extends Error {}

const PROBE = /^[a-z0-9-]{1,40}$/
const WORD = /^[a-z0-9_-]{1,32}$/
/** Results one canary request may carry (one per probe of a round). */
export const MAX_RESULTS = 8

/** The canary results in `body` (`{results: [...]}`), or a CanaryError naming what is wrong. */
export const parseCanary = (body: Record<string, unknown>): Array<CanaryResult> => {
  const list = body.results
  if (!Array.isArray(list) || !list.length || list.length > MAX_RESULTS) throw new CanaryError(`results must be 1-${MAX_RESULTS} canary results`)
  return list.map((raw, i) => {
    if (typeof raw !== "object" || raw === null) throw new CanaryError(`results[${i}] must be an object`)
    const r = raw as Record<string, unknown>
    if (typeof r.probe !== "string" || !PROBE.test(r.probe)) throw new CanaryError(`results[${i}].probe must be 1-40 lowercase letters, digits or dashes`)
    if (r.outcome !== "pass" && r.outcome !== "fail") throw new CanaryError(`results[${i}].outcome must be pass or fail`)
    const step = r.step as CanaryStep
    if (r.outcome === "fail" && !STEPS.has(step)) throw new CanaryError(`results[${i}] failed without a known step`)
    if (typeof r.at !== "string" || Number.isNaN(Date.parse(r.at))) throw new CanaryError(`results[${i}].at must be an ISO 8601 date`)
    const mac = typeof r.mac === "object" && r.mac !== null ? (r.mac as Record<string, unknown>) : {}
    if (typeof mac.id !== "string" || !mac.id.trim()) throw new CanaryError(`results[${i}].mac.id is required`)
    const ms = typeof r.durationMs === "number" && Number.isFinite(r.durationMs) && r.durationMs >= 0 ? Math.min(Math.round(r.durationMs), 600_000) : 0
    const word = (v: unknown) => (typeof v === "string" && WORD.test(v) ? v : undefined)
    const transport = word(r.transport)
    const path = word(r.path)
    return {
      probe: r.probe,
      at: new Date(Date.parse(r.at)).toISOString(),
      outcome: r.outcome,
      ...(r.outcome === "fail" ? { step } : {}),
      ...(r.outcome === "fail" && typeof r.error === "string" && r.error.trim() ? { error: r.error.trim().slice(0, 300) } : {}),
      ...(transport ? { transport } : {}),
      ...(path ? { path } : {}),
      durationMs: ms,
      mac: { id: mac.id.trim().toLowerCase().slice(0, 64), name: typeof mac.name === "string" && mac.name.trim() ? mac.name.trim().slice(0, 80) : "canary Mac" }
    }
  })
}

/** Whose fault a failed run is: the service (or the network to it), or the canary's own Mac. */
export type CanaryClass = "service" | "host_down"

/** How far past a run's end a ping still speaks for it (the canary reports each run as it ends; hosts ping every 15 s). */
export const PING_AFTER_RUN_MS = 30_000

/**
 * A failure before the canary needed its Mac is the service's. A failure at the Mac's end is the service's only
 * if that Mac proved it was awake around the run: an application ping from ALIVE_WITHIN_MS before the run's start
 * (`at`, clamped to now: a canary clock that runs fast is judged now) to shortly after its end. A Mac that is not
 * pinging is the canary's own host down. A liveness the hub could not give (`null`: the hub itself failed) is
 * never blamed on the canary's Mac: a broken hub is the service.
 */
export const classify = (result: CanaryResult, check: MacCheck, now: number): CanaryClass => {
  if (result.step && SERVICE_STEPS.has(result.step)) return "service"
  const live = check.liveness
  if (live === null) return "service"
  const at = Math.min(now, Date.parse(result.at))
  const ping = live.lastPingAt
  return live.connected && ping != null && ping >= at - ALIVE_WITHIN_MS && ping <= at + result.durationMs + PING_AFTER_RUN_MS ? "service" : "host_down"
}

/** Failures in a row at the same step (and of the same class) before a canary incident is posted. */
export const STRIKES = 3
/** The canary is silent (alerting blind) after this long without a report. */
export const CANARY_SILENT_MS = 10 * 60_000
/** No team phone checking in for this much working time means the alerting is blind. */
export const HEARTBEAT_SILENT_WORK_MS = 4 * 3_600_000
/** Resolved canary incidents are forgotten after this long. */
export const CANARY_RETENTION_MS = 7 * 86_400_000

export interface ProbeState {
  /** The last result's own time (the canary's clock): a resend is never counted twice. */
  lastAt: number
  streak: number
  streakStep?: CanaryStep
  streakClass?: CanaryClass
  /** When the current streak's first failure was seen. */
  streakSince?: number
  /** The probe's open incident. */
  open?: string
}

export type WatchKind = "service" | "host_down" | "blind_canary" | "blind_heartbeat"

export interface WatchIncident {
  /** `canary:<uuid>`: a ':' no phone incident id can hold, so the two never share a storage key. */
  readonly id: string
  readonly kind: WatchKind
  readonly probe?: string
  step?: CanaryStep
  readonly startedAt: number
  updatedAt: number
  failures?: number
  lastError?: string
  transport?: string
  path?: string
  mac?: { id: string; name: string }
  resolvedAt?: number
  /** A later canary incident of the same kind: posted in this earlier one's thread. */
  parent?: string
  slack?: { channel: string; ts: string }
  /** Held back by the hourly limit (never posted). */
  held?: boolean
}

export interface WatchState {
  probes: Record<string, ProbeState>
  lastCanaryAt?: number
  lastTeamHeartbeatAt?: number
  lastTestHeartbeatAt?: number
  /** workDeadline of lastTeamHeartbeatAt, kept so the alarm's every look costs no time-zone walk. */
  heartbeatDue?: { from: number; at: number | null }
  /** The open "alerting is blind" incidents. */
  blind: { canary?: string; heartbeat?: string }
}

export const emptyWatch = (): WatchState => ({ probes: {}, blind: {} })
export const normalizeWatch = (w: Partial<WatchState> | undefined): WatchState => ({ probes: w?.probes ?? {}, blind: w?.blind ?? {}, ...(w?.heartbeatDue ? { heartbeatDue: w.heartbeatDue } : {}), ...(w?.lastCanaryAt != null ? { lastCanaryAt: w.lastCanaryAt } : {}), ...(w?.lastTeamHeartbeatAt != null ? { lastTeamHeartbeatAt: w.lastTeamHeartbeatAt } : {}), ...(w?.lastTestHeartbeatAt != null ? { lastTestHeartbeatAt: w.lastTestHeartbeatAt } : {}) })

/** The canary's reporter key in the desk's hourly counts. */
export const CANARY_REPORTER = "canary"

export interface WatchOutcome {
  readonly actions: Array<SlackAction>
  /** Watch incidents written. */
  readonly changed: Array<string>
}

const newId = () => `canary:${crypto.randomUUID()}`

const STEP_WORDS: Record<CanaryStep, string> = {
  auth: "signing in",
  ice: "getting TURN servers (/v1/ice)",
  register: "registering its device",
  signaling: "opening the signaling socket",
  presence: "seeing its Mac online",
  dial: "connecting to its Mac",
  ping: "pinging its Mac over the link"
}

const PROBE_WORDS: Record<string, string> = {
  wireguard: "WireGuard",
  "wireguard-turn-tls": "WireGuard, TURN over TLS forced",
  webrtc: "WebRTC",
  "webrtc-relay": "WebRTC, TURN relay forced"
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
const when = (ms: number) => `<!date^${Math.floor(ms / 1000)}^{date_short_pretty} {time_secs}|${new Date(ms).toISOString()}>`

/** The whole message for a watch incident at `now`. */
export const renderWatch = (incident: WatchIncident, now: number): string => {
  const resolved = incident.resolvedAt !== undefined
  const lasted = duration((incident.resolvedAt ?? now) - incident.startedAt)
  const probe = incident.probe ? (PROBE_WORDS[incident.probe] ?? esc(incident.probe)) : ""
  const mac = incident.mac ? `“${esc(incident.mac.name)}”` : "its Mac"
  const lines: Array<string> = []
  switch (incident.kind) {
    case "service":
      lines.push(
        resolved
          ? `:large_green_circle: *The connectivity canary couldn't connect (${probe})* — passing again after ${lasted}`
          : `:red_circle: *The connectivity canary can't connect (${probe})* — failing at ${STEP_WORDS[incident.step!]} for ${lasted}, ${incident.failures ?? STRIKES} runs in a row`
      )
      if (!resolved) lines.push(`• Its Mac ${mac} is awake (it pings the service), so this is the cmux service or the network path, not the Mac. Teammates' phones are likely affected too.`)
      break
    case "host_down":
      lines.push(
        resolved
          ? `:large_green_circle: *The canary's own Mac ${mac} was down* — back after ${lasted}`
          : `:large_yellow_circle: *The canary's own Mac ${mac} is down* — not pinging the service for ${lasted}; the canary can't check connectivity until it's back`
      )
      if (!resolved) lines.push("• Not a service outage: the Mac the canary dials is asleep, offline or its host stopped. Fix the canary host.")
      break
    case "blind_canary":
      lines.push(
        resolved
          ? `:large_green_circle: *The connectivity canary was silent* — reporting again after ${lasted}`
          : `:black_circle: *Connectivity alerting is blind: the canary hasn't reported for ${lasted}*`
      )
      if (!resolved) lines.push("• Its host, its network or this alert service may be down. Outages nobody is using the app through go unheard until it reports again.")
      break
    case "blind_heartbeat":
      lines.push(
        resolved
          ? `:large_green_circle: *Team phones were silent* — a team phone checked in again after ${lasted}`
          : `:black_circle: *Connectivity alerting may be blind: no team phone has checked in for 4h of working time*`
      )
      if (!resolved) lines.push("• Either nobody on the team opened the app, or phones can't reach this alert service (an app release, the Worker, or sign-in). Check that the app still reports.")
      break
  }
  const detail: Array<string> = []
  if (incident.lastError && !resolved) detail.push(`last error: \`${esc(incident.lastError).replace(/`/g, "'")}\``)
  if (incident.path && !resolved) detail.push(`path ${esc(incident.path)}`)
  if (detail.length) lines.push(`• ${detail.join(" · ")}`)
  lines.push(`_Canary incident \`${incident.id.slice(7, 15)}\` · started ${when(incident.startedAt)}_`)
  return lines.join("\n")
}

const endLine = (incident: WatchIncident): string =>
  incident.kind === "service"
    ? `Resolved: the canary passed again after ${duration(incident.resolvedAt! - incident.startedAt)}.`
    : incident.kind === "host_down"
      ? `Resolved: the canary's Mac is back after ${duration(incident.resolvedAt! - incident.startedAt)}.`
      : `Resolved after ${duration(incident.resolvedAt! - incident.startedAt)}.`

/**
 * Opens a watch incident, threaded under an earlier one of the same kind within THREAD_WINDOW_MS (the other
 * probes of one outage). Limits: a service outage is never held (the canary exists to say it), and "alerting is
 * blind" posts are at most two at a time. Only a new "canary's own Mac is down" outage counts against the
 * desk's hourly limits (as the canary reporter), threaded or not; the other probes of the same open outage are
 * free, so a flapping canary Mac uses one slot per outage. `changed` collects the parent whose thread window this extends.
 */
const open = (desk: DeskState, incidents: Record<string, WatchIncident>, incident: WatchIncident, now: number, changed: Set<string>): Array<SlackAction> => {
  incidents[incident.id] = incident
  const parent = Object.values(incidents)
    .filter((i) => i.id !== incident.id && !i.parent && !i.held && i.kind === incident.kind && (i.resolvedAt === undefined || now - i.updatedAt <= THREAD_WINDOW_MS))
    .sort((a, b) => b.updatedAt - a.updatedAt)[0]
  // The other probes of an outage still open (same kind, unresolved): held with it if it was held, else free.
  const ongoing = Object.values(incidents).filter((i) => i.id !== incident.id && i.kind === incident.kind && i.resolvedAt === undefined)
  if (ongoing.length && ongoing.every((i) => i.held)) {
    incident.held = true
    return []
  }
  // A new outage of the canary's Mac takes one slot.
  if (incident.kind === "host_down" && !ongoing.length) {
    desk.meta.posted = desk.meta.posted.filter((p) => now - p.at < 3_600_000)
    const mine = desk.meta.posted.filter((p) => p.reporter === CANARY_REPORTER).length
    if (mine >= LIMITS.perReporterPerHour || desk.meta.posted.length >= LIMITS.overallPerHour) {
      incident.held = true
      if (!desk.meta.held.team.some((h) => h.id === incident.id)) desk.meta.held.team.push({ id: incident.id, at: now })
      return []
    }
    desk.meta.posted.push({ at: now, reporter: CANARY_REPORTER, route: "team" })
  }
  const text = renderWatch(incident, now)
  if (parent) {
    incident.parent = parent.id
    parent.updatedAt = now
    changed.add(parent.id)
    return [{ kind: "post", incident: incident.id, route: "team", text: `Again: ${text}`, thread: parent.id }]
  }
  return [{ kind: "post", incident: incident.id, route: "team", text }]
}

/** Closes a watch incident: its message is edited, and a top message also gets a reply. A held one stays quiet. */
const close = (incidents: Record<string, WatchIncident>, id: string, now: number): Array<SlackAction> => {
  const incident = incidents[id]
  if (!incident || incident.resolvedAt !== undefined) return []
  incident.resolvedAt = now
  incident.updatedAt = now
  if (incident.held) return []
  return incident.parent
    ? [{ kind: "update", incident: id, text: `Again: ${renderWatch(incident, now)}\n${endLine(incident)}`, thread: incident.parent }]
    : [
        { kind: "update", incident: id, text: renderWatch(incident, now) },
        { kind: "reply", incident: id, text: endLine(incident) }
      ]
}

/**
 * Applies one canary result. `check` is the canary Mac's liveness around the run. Idempotent enough for a
 * resend: a result older than the probe's last one changes nothing.
 */
export const applyCanary = (
  desk: DeskState,
  watch: WatchState,
  incidents: Record<string, WatchIncident>,
  result: CanaryResult,
  check: MacCheck,
  now: number
): WatchOutcome => {
  const actions: Array<SlackAction> = []
  const changed = new Set<string>()
  // Any report, pass or fail, is the canary alive.
  watch.lastCanaryAt = now
  if (watch.blind.canary) {
    actions.push(...close(incidents, watch.blind.canary, now))
    changed.add(watch.blind.canary)
    delete watch.blind.canary
  }
  // One streak per (Mac, probe): a second canary (another install, a developer's run) never mixes with this one.
  const raw = Date.parse(result.at)
  const at = Math.min(now, raw)
  const probe = (watch.probes[`${result.mac.id}/${result.probe}`] ??= { lastAt: 0, streak: 0 })
  if (raw <= probe.lastAt) return { actions, changed: [...changed] }
  probe.lastAt = raw
  if (result.outcome === "pass") {
    probe.streak = 0
    delete probe.streakStep
    delete probe.streakClass
    delete probe.streakSince
    if (probe.open) {
      actions.push(...close(incidents, probe.open, now))
      changed.add(probe.open)
      delete probe.open
    }
    return { actions, changed: [...changed] }
  }
  const cls = classify(result, check, now)
  if (probe.streakStep === result.step && probe.streakClass === cls) probe.streak += 1
  else {
    probe.streak = 1
    probe.streakStep = result.step!
    probe.streakClass = cls
    probe.streakSince = at
  }
  const current = probe.open ? incidents[probe.open] : undefined
  if (current) {
    current.failures = (current.failures ?? 0) + 1
    current.updatedAt = now
    if (result.error) current.lastError = result.error
    if (result.step) current.step = result.step
    changed.add(current.id)
    // The Mac woke up but the service still fails it (or the reverse): the open incident is the wrong one.
    if (probe.streak >= STRIKES && current.kind !== cls) {
      actions.push(...close(incidents, current.id, now))
      delete probe.open
    } else return { actions, changed: [...changed] }
  }
  if (probe.streak < STRIKES) return { actions, changed: [...changed] }
  const incident: WatchIncident = {
    id: newId(),
    kind: cls,
    probe: result.probe,
    step: result.step!,
    startedAt: probe.streakSince ?? at,
    updatedAt: now,
    failures: probe.streak,
    ...(result.error ? { lastError: result.error } : {}),
    ...(result.transport ? { transport: result.transport } : {}),
    ...(result.path ? { path: result.path } : {}),
    mac: { ...result.mac }
  }
  probe.open = incident.id
  actions.push(...open(desk, incidents, incident, now, changed))
  changed.add(incident.id)
  return { actions, changed: [...changed] }
}

/** A phone heartbeat: a team phone's resolves "no team phone checked in". */
export const applyHeartbeat = (watch: WatchState, incidents: Record<string, WatchIncident>, route: "team" | "test", now: number): WatchOutcome => {
  if (route === "test") {
    watch.lastTestHeartbeatAt = now
    return { actions: [], changed: [] }
  }
  watch.lastTeamHeartbeatAt = now
  heartbeatDue(watch)
  const id = watch.blind.heartbeat
  if (!id) return { actions: [], changed: [] }
  delete watch.blind.heartbeat
  return { actions: close(incidents, id, now), changed: [id] }
}

// MARK: Working time (weekdays 9:00-19:00 America/Los_Angeles)

const pacific = new Intl.DateTimeFormat("en-US", { timeZone: "America/Los_Angeles", weekday: "short", hour: "numeric", hourCycle: "h23" })
const STEP_MS = 5 * 60_000

/** Whether `ms` falls in working time (weekdays 9:00-19:00 Pacific). */
export const isWorkTime = (ms: number): boolean => {
  const parts = pacific.formatToParts(new Date(ms))
  const day = parts.find((p) => p.type === "weekday")?.value
  const hour = Number(parts.find((p) => p.type === "hour")?.value)
  return day !== "Sat" && day !== "Sun" && hour >= 9 && hour < 19
}

/**
 * The first moment at which `work` of working time has passed since `from` (to 5 minutes), or undefined past
 * 14 days. A weekend or a night never counts, so Monday 9:00 is not 60 hours of silence.
 */
export const workDeadline = (from: number, work: number): number | undefined => {
  let spent = 0
  const start = Math.ceil(from / STEP_MS) * STEP_MS
  for (let t = start; t < from + 14 * 86_400_000; t += STEP_MS) {
    if (isWorkTime(t)) spent += STEP_MS
    if (spent >= work) return t + STEP_MS
  }
  return undefined
}

/** When 4 working hours have passed since the last team heartbeat (computed once per heartbeat). */
const heartbeatDue = (watch: WatchState): number | undefined => {
  const from = watch.lastTeamHeartbeatAt
  if (from == null) return undefined
  if (watch.heartbeatDue?.from !== from) watch.heartbeatDue = { from, at: workDeadline(from, HEARTBEAT_SILENT_WORK_MS) ?? null }
  return watch.heartbeatDue.at ?? undefined
}

/** When the watch next has to look at the clock, if ever: the canary's silence or the team phones' silence. */
export const nextWatchDue = (watch: WatchState): number | undefined => {
  const due: Array<number> = []
  if (watch.lastCanaryAt != null && !watch.blind.canary) due.push(watch.lastCanaryAt + CANARY_SILENT_MS)
  if (watch.lastTeamHeartbeatAt != null && !watch.blind.heartbeat) {
    const t = heartbeatDue(watch)
    if (t !== undefined) due.push(t)
  }
  return due.length ? Math.min(...due) : undefined
}

/**
 * The alarm's look at the watch: posts "alerting is blind" once per silence. Nothing is posted before the
 * canary or a team phone has ever reported (a deploy before the canary is installed stays quiet).
 */
export const checkSilence = (desk: DeskState, watch: WatchState, incidents: Record<string, WatchIncident>, now: number): WatchOutcome => {
  const actions: Array<SlackAction> = []
  const changed = new Set<string>()
  if (watch.lastCanaryAt != null && !watch.blind.canary && now - watch.lastCanaryAt >= CANARY_SILENT_MS) {
    const incident: WatchIncident = { id: newId(), kind: "blind_canary", startedAt: watch.lastCanaryAt, updatedAt: now }
    watch.blind.canary = incident.id
    actions.push(...open(desk, incidents, incident, now, changed))
    changed.add(incident.id)
  }
  if (watch.lastTeamHeartbeatAt != null && !watch.blind.heartbeat) {
    const due = heartbeatDue(watch)
    if (due !== undefined && now >= due) {
      const incident: WatchIncident = { id: newId(), kind: "blind_heartbeat", startedAt: watch.lastTeamHeartbeatAt, updatedAt: now }
      watch.blind.heartbeat = incident.id
      actions.push(...open(desk, incidents, incident, now, changed))
      changed.add(incident.id)
    }
  }
  return { actions, changed: [...changed] }
}

/** Watch incidents resolved long ago (or held and done): forgotten. */
export const staleWatch = (incidents: Record<string, WatchIncident>, now: number): Array<string> =>
  Object.values(incidents)
    .filter((i) => i.resolvedAt !== undefined && now - i.resolvedAt > CANARY_RETENTION_MS)
    .map((i) => i.id)

/** The storage key of an incident the desk's outbox names: phone incidents under `inc:`, the watch's under `can:`. */
export const storageKey = (id: string): string => (id.startsWith("canary:") ? `can:${id}` : `inc:${id}`)

/** The canary's accounts: the agent test account unless the env names others (comma-separated). */
export const DEFAULT_CANARY_EMAILS = ["cmux-agent-development@manaflow.ai"]

export const isCanaryEmail = (email: string | null, configured?: string): boolean => {
  if (!email) return false
  const list = configured?.trim() ? configured.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean) : DEFAULT_CANARY_EMAILS
  return list.includes(email.trim().toLowerCase())
}
