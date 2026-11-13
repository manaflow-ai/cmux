import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import type { MacLiveness } from "./team-hub.ts"

/**
 * Connectivity alerts (PROTOCOL.md "Connectivity incidents"): a cmux team member's phone reports a major
 * connectivity incident (a Mac it could not reach while everything said it should, or a link that kept
 * dropping), and the cmux team's Slack channel hears about it once, with its end edited in.
 *
 * Who is heard is decided here, never by the phone: the reporter's verified Stack email must be on a team
 * domain; agent or service accounts, simulators, Debug builds and developer network simulations go to the
 * test channel (or nowhere). Whether the Mac was awake is decided here too, from its signaling socket's
 * application pings (TeamHub.macLiveness): a Mac that sleeps keeps its socket half open, so presence says
 * "online" while nothing can reach it, and that is not a cmux incident. The phone decides what is major by
 * rules it can see (CmuxMobileLive ConnectivityIncidentDetector).
 */

/** The cmux team's email domains (ConnectivityAudience.teamDomains on the phone; keep the two equal). */
export const TEAM_DOMAINS = ["manaflow.ai", "cmux.com", "manaflow.com"] as const

/** Team-domain accounts that are agents or services, not people: their phones never page the team. */
const DEFAULT_EXCLUDED = ["cmux-agent-development@manaflow.ai"]
const EXCLUDED_PREFIXES = ["cmux-agent-"]

export type TestReason = "simulator" | "agent_account" | "debug_build" | "network_simulation"
/** Where a verified reporter's incidents go. */
export type Audience = { route: "team" } | { route: "test"; why: TestReason } | { route: "refuse"; why: "not_team" | "unverified" }

/** Whether `email`'s domain is a team domain, exactly or as a subdomain (look-alikes are not). */
export const isTeamEmail = (email: string): boolean => {
  const at = email.lastIndexOf("@")
  if (at <= 0) return false
  const domain = email.slice(at + 1).trim().toLowerCase()
  return TEAM_DOMAINS.some((team) => domain === team || domain.endsWith(`.${team}`))
}

/** Where a report from this account and build goes. `excluded` is the env's extra list (comma-separated). */
export const audienceOf = (
  email: string | null,
  verified: boolean,
  build: { readonly simulator: boolean; readonly config: string; readonly simulations?: ReadonlyArray<string> },
  excluded = ""
): Audience => {
  if (!email || !isTeamEmail(email)) return { route: "refuse", why: "not_team" }
  if (!verified) return { route: "refuse", why: "unverified" }
  const lower = email.trim().toLowerCase()
  const local = lower.slice(0, lower.lastIndexOf("@"))
  const list = [...DEFAULT_EXCLUDED, ...excluded.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean)]
  if (list.includes(lower) || EXCLUDED_PREFIXES.some((p) => local.startsWith(p))) return { route: "test", why: "agent_account" }
  if (build.simulator) return { route: "test", why: "simulator" }
  if (build.simulations?.length) return { route: "test", why: "network_simulation" }
  if (build.config === "Debug") return { route: "test", why: "debug_build" }
  return { route: "team" }
}

// MARK: The report

export type IncidentKind = "mac_unreachable" | "link_unstable"
export type IncidentState = "open" | "resolved" | "ended"
/** How an incident ended without the Mac answering again. */
export type EndReason = "app_backgrounded" | "network_lost" | "mac_offline" | "link_closed" | "signed_out" | "app_relaunched" | "no_end_reported"

export interface IncidentReport {
  readonly id: string
  readonly kind: IncidentKind
  readonly state: IncidentState
  readonly endReason?: EndReason
  /** When the incident began (the link stopped working), ISO 8601. */
  readonly startedAt: string
  /** When the phone saw this state, ISO 8601. */
  readonly observedAt: string
  /** How long it lasted up to `observedAt`. */
  readonly durationMs: number
  readonly mac: { readonly id: string; readonly name: string }
  /** Dials tried while the Mac was unreachable. */
  readonly attempts?: number
  /** Drops of a live link inside the window (link_unstable). */
  readonly drops?: number
  /** The last failure as the phone saw it (free text; the team's own). */
  readonly lastError?: string
  readonly transport?: string
  /** Whether the phone could reach the cmux service while the Mac could not be reached. */
  readonly serviceReachable?: boolean
  readonly network?: string
  readonly app: { readonly version: string; readonly build: string; readonly config: string; readonly simulator: boolean }
  readonly device: { readonly model: string; readonly os: string }
  /** Developer network simulations that were on (relay only, UDP blocked). */
  readonly simulations?: ReadonlyArray<string>
}

const ID = /^[A-Za-z0-9-]{8,64}$/
const KINDS = new Set<IncidentKind>(["mac_unreachable", "link_unstable"])
const STATES = new Set<IncidentState>(["open", "resolved", "ended"])
const END_REASONS = new Set<EndReason>(["app_backgrounded", "network_lost", "mac_offline", "link_closed", "signed_out", "app_relaunched"])
const WORD = /^[a-z0-9_]{1,32}$/
const SIMULATIONS = new Set(["relay_only", "block_udp"])

export class ReportError extends Error {}

/** A required identifying string. */
const required = (v: unknown, field: string, max: number): string => {
  if (typeof v !== "string" || !v.trim()) throw new ReportError(`${field} is required`)
  return v.trim().slice(0, max)
}
/** A descriptive string: anything unusable is left out (or `fallback`), never a reason to lose the report. */
const descriptive = (v: unknown, max: number, fallback?: string): string | undefined =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, max) : fallback
const date = (v: unknown, field: string): string => {
  const s = required(v, field, 40)
  if (Number.isNaN(Date.parse(s))) throw new ReportError(`${field} must be an ISO 8601 date`)
  return new Date(Date.parse(s)).toISOString()
}
const count = (v: unknown, max: number): number | undefined =>
  typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.min(Math.round(v), max) : undefined
const obj = (v: unknown, field: string): Record<string, unknown> => {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new ReportError(`${field} must be an object`)
  return v as Record<string, unknown>
}

/**
 * The report in `body`, or a ReportError naming what is wrong. Only what identifies and times the incident
 * is required; a descriptive field that is empty or malformed is left out, so an odd Mac name or a phone
 * that sends a new word never loses an alert.
 */
export const parseReport = (body: Record<string, unknown>): IncidentReport => {
  const id = required(body.id, "id", 64)
  if (!ID.test(id)) throw new ReportError("id must be 8-64 letters, digits or dashes")
  const kind = body.kind as IncidentKind
  if (!KINDS.has(kind)) throw new ReportError("kind must be mac_unreachable or link_unstable")
  const state = body.state as IncidentState
  if (!STATES.has(state)) throw new ReportError("state must be open, resolved or ended")
  let endReason: EndReason | undefined
  if (state === "ended") {
    endReason = body.endReason as EndReason
    if (!END_REASONS.has(endReason)) throw new ReportError("an ended incident needs its endReason")
  }
  const mac = obj(body.mac, "mac")
  const app = obj(body.app, "app")
  const device = typeof body.device === "object" && body.device !== null ? (body.device as Record<string, unknown>) : {}
  const durationMs = count(body.durationMs, 30 * 86_400_000)
  if (durationMs === undefined) throw new ReportError("durationMs must be a non-negative number")
  if (typeof app.simulator !== "boolean") throw new ReportError("app.simulator must be a boolean")
  const word = (v: unknown) => {
    const s = descriptive(v, 32)
    return s !== undefined && WORD.test(s) ? s : undefined
  }
  const transport = word(body.transport)
  const network = word(body.network)
  const simulations = Array.isArray(body.simulations) ? body.simulations.filter((s): s is string => typeof s === "string" && SIMULATIONS.has(s)) : []
  const attempts = count(body.attempts, 100_000)
  const drops = count(body.drops, 100_000)
  const lastError = descriptive(body.lastError, 300)
  return {
    id,
    kind,
    state,
    ...(endReason ? { endReason } : {}),
    startedAt: date(body.startedAt, "startedAt"),
    observedAt: date(body.observedAt, "observedAt"),
    durationMs,
    mac: { id: required(mac.id, "mac.id", 64), name: descriptive(mac.name, 80, "Unnamed Mac")! },
    ...(attempts !== undefined ? { attempts } : {}),
    ...(drops !== undefined ? { drops } : {}),
    ...(lastError !== undefined ? { lastError } : {}),
    ...(transport !== undefined ? { transport } : {}),
    ...(typeof body.serviceReachable === "boolean" ? { serviceReachable: body.serviceReachable } : {}),
    ...(network !== undefined ? { network } : {}),
    app: {
      version: descriptive(app.version, 24, "?")!,
      build: descriptive(app.build, 24, "?")!,
      config: descriptive(app.config, 24, "?")!,
      simulator: app.simulator
    },
    device: { model: descriptive(device.model, 48, "unknown")!, os: descriptive(device.os, 24, "?")! },
    ...(simulations.length ? { simulations } : {})
  }
}

// MARK: The desk (pure): what each report does to Slack

/** Per-reporter and overall limits on new Slack threads, per sliding hour and channel. */
export const LIMITS = { perReporterPerHour: 5, overallPerHour: 20 } as const
/** Incidents kept per reporter (a phone gone wrong cannot fill the desk). */
export const PER_REPORTER_STORED = 100
/** Reports of a Mac outage from more teammates than one inside this window suggest the service. */
export const CORRELATION_WINDOW_MS = 10 * 60_000
/** How long an incident is remembered (so a late duplicate or end still finds its message). */
export const RETENTION_MS = 7 * 86_400_000
/** A Mac is awake when its socket sent an application ping this recently. Hosts ping every 15 s. */
export const ALIVE_WITHIN_MS = 45_000
/** A report delivered this long after the phone saw it says so in its message. */
export const LATE_MS = 2 * 60_000
/** A new incident for the same reporter and Mac (either kind) this soon after the last one goes in its thread. */
export const THREAD_WINDOW_MS = 30 * 60_000

export interface Reporter {
  readonly key: string
  readonly email: string
}

/** Why an incident was not posted. */
export type Suppressed = "rate_limited" | "mac_asleep" | "mac_offline" | "mac_liveness_unknown"

export interface Incident {
  readonly id: string
  readonly route: "team" | "test"
  /** Why it is on the test route. */
  readonly why?: TestReason
  readonly reporter: Reporter
  /** The first state seen (the start, normally). */
  readonly report: IncidentReport
  /** Every state seen, in arrival order. */
  readonly states: Array<IncidentState>
  readonly receivedAt: number
  updatedAt: number
  /** Its post is queued (it may not be sent yet): later states edit that message rather than post again. */
  queued?: boolean
  /** The Slack message, once posted. */
  slack?: { channel: string; ts: string }
  /** A later incident of the same reporter and Mac: posted in this earlier incident's thread. */
  parent?: string
  suppressed?: Suppressed
  /** Its message was closed because no end came within OPEN_EXPIRY_MS. */
  expired?: boolean
}

export interface DeskMeta {
  /** Messages and thread replies posted for new incidents, by time (sliding-hour limits). */
  posted: Array<{ at: number; reporter: string; route: "team" | "test" }>
  /** Incidents held back by a limit and not yet told, per route: the next post says how many in its hour. */
  held: Record<"team" | "test", Array<{ id: string; at: number }>>
}

export interface DeskState {
  incidents: Record<string, Incident>
  meta: DeskMeta
}

export const emptyDesk = (): DeskState => ({ incidents: {}, meta: { posted: [], held: { team: [], test: [] } } })

/** A stored desk from before `held` (an older deploy) reads as an empty one. */
export const normalizeMeta = (meta: Partial<DeskMeta> | undefined): DeskMeta => ({
  posted: meta?.posted ?? [],
  held: { team: meta?.held?.team ?? [], test: meta?.held?.test ?? [] }
})

/** Held-back incidents of the last hour on a route, not yet told. */
const heldInHour = (desk: DeskState, route: "team" | "test", now: number) => desk.meta.held[route].filter((h) => now - h.at < 3_600_000)

/**
 * One Slack call the desk wants made, in order. `incident` names the message it posts, edits or replies to.
 * A post with `thread` is that incident's own message inside another incident's thread (an "Again:"
 * reply); an update with `thread` falls back to a reply there when the incident's own message is unknown.
 */
export type SlackAction =
  | { kind: "post"; incident: string; route: "team" | "test"; text: string; thread?: string }
  | { kind: "update"; incident: string; text: string; thread?: string }
  | { kind: "reply"; incident: string; text: string }

export interface DeskOutcome {
  readonly accepted: boolean
  /** Why nothing was sent (duplicate, rate_limited, mac_asleep, ...), for the response and the log. */
  readonly note?: string
  readonly actions: ReadonlyArray<SlackAction>
  /** Incidents written or deleted (the storage keys to update). */
  readonly changed: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
}

const HOUR = 3_600_000

/** What the desk knows about the reported Mac when the report arrives. */
export type MacCheck = { readonly liveness: MacLiveness | null }

/** The moment an incident is judged at: when the phone saw it (never later than now). */
export const judgedAt = (report: IncidentReport, now: number): number => Math.min(now, Date.parse(report.observedAt))

/**
 * Whether an incident's start may be posted.
 * - The cmux service failing the phone always may (that outage is ours, whatever the Mac does).
 * - A link that kept dropping always may: the phone reports it only once its link to the Mac is up again,
 *   so the Mac is demonstrably awake (a Mac that sleeps never reconnects).
 * - A Mac the phone could not reach must have sent an application ping after the link stopped working
 *   (`startedAt`, and within ALIVE_WITHIN_MS of the moment the phone saw it; the liveness passed in speaks
 *   for that moment, so a late report is judged as it was). An awake host pings every 15 s through the 30 s
 *   stretch; one that froze or slept as the link stopped cannot, however recently it pinged before. A
 *   connect alone is no proof: a dark wake connects and goes back to sleep.
 */
export const startVerdict = (report: IncidentReport, check: MacCheck, now: number): Suppressed | undefined => {
  if (report.serviceReachable === false) return undefined
  if (report.kind === "link_unstable") return undefined
  const live = check.liveness
  const at = judgedAt(report, now)
  const since = Math.max(Date.parse(report.startedAt), at - ALIVE_WITHIN_MS)
  if (live && live.lastPingAt !== null && live.lastPingAt >= since) return undefined
  if (!live || !live.connected) return "mac_offline"
  if (!live.pings) return "mac_liveness_unknown"
  return "mac_asleep"
}

/**
 * Applies one verified report to the desk at `now`. Idempotent per (incident, state): a resend of a state
 * already seen changes nothing. An end of an incident whose start was held back by a limit is posted whole
 * once allowed, so a major outage is never lost to a limit; an end of an incident whose Mac was asleep stays
 * quiet with it.
 */
export const applyReport = (desk: DeskState, report: IncidentReport, reporter: Reporter, audience: { route: "team" | "test"; why?: TestReason }, check: MacCheck, now: number): DeskOutcome => {
  const removed: Array<string> = []
  desk.meta.posted = desk.meta.posted.filter((p) => now - p.at < HOUR)
  for (const route of ["team", "test"] as const) desk.meta.held[route] = heldInHour(desk, route, now)
  for (const [id, incident] of Object.entries(desk.incidents))
    if (now - incident.updatedAt > RETENTION_MS) {
      delete desk.incidents[id]
      removed.push(id)
    }
  const done = (o: Omit<DeskOutcome, "removed">): DeskOutcome => ({ ...o, removed })

  const known = desk.incidents[report.id]
  if (known && known.reporter.key !== reporter.key) return done({ accepted: false, note: "foreign_incident", actions: [], changed: [] })
  if (known?.states.includes(report.state)) return done({ accepted: true, note: "duplicate", actions: [], changed: [] })
  // An incident ends once, and a start after its end adds nothing.
  if (known && (report.state === "open" || known.states.some((s) => s !== "open"))) return done({ accepted: true, note: "duplicate", actions: [], changed: [] })

  if (known) {
    known.states.push(report.state)
    known.updatedAt = now
    if (known.queued) {
      const end = endLine(report)
      // A thread child's own reply is edited to its end; a top message is edited and gets a reply.
      const actions: Array<SlackAction> = known.parent
        ? [{ kind: "update", incident: known.id, text: `Again: ${render(known, report, desk, now)}\n${end}`, thread: known.parent }]
        : [
            { kind: "update", incident: known.id, text: render(known, report, desk, now) },
            { kind: "reply", incident: known.id, text: end }
          ]
      return done({ accepted: true, actions, changed: [known.id] })
    }
    // Its Mac was asleep or offline when it started: its end is not news either.
    if (known.suppressed !== "rate_limited") return done({ accepted: true, note: known.suppressed, actions: [], changed: [known.id] })
    return done({ ...postNew(desk, known, report, now), changed: [known.id] })
  }

  if (Object.values(desk.incidents).filter((i) => i.reporter.key === reporter.key).length >= PER_REPORTER_STORED)
    return done({ accepted: true, note: "reporter_cap", actions: [], changed: [] })
  const incident: Incident = {
    id: report.id,
    route: audience.route,
    ...(audience.why ? { why: audience.why } : {}),
    reporter,
    report,
    states: [report.state],
    receivedAt: now,
    updatedAt: now
  }
  desk.incidents[report.id] = incident
  // A start (or an end whose start was lost) is posted only for a Mac that was awake.
  const verdict = startVerdict(report, check, now)
  if (verdict) {
    incident.suppressed = verdict
    return done({ accepted: true, note: verdict, actions: [], changed: [report.id] })
  }
  return done({ ...postNew(desk, incident, report, now), changed: [report.id] })
}

const postNew = (desk: DeskState, incident: Incident, report: IncidentReport, now: number): Omit<DeskOutcome, "changed" | "removed"> => {
  const route = incident.route
  // Every new incident counts against the hour's limits, a thread reply too: a person going back and forth
  // between the app and the background on one dead Mac never posts more than the limit.
  const mine = desk.meta.posted.filter((p) => p.route === route && p.reporter === incident.reporter.key).length
  const all = desk.meta.posted.filter((p) => p.route === route).length
  if (mine >= LIMITS.perReporterPerHour || all >= LIMITS.overallPerHour) {
    // Counted once, however many of its states arrive while the limit holds.
    if (!desk.meta.held[route].some((h) => h.id === incident.id)) desk.meta.held[route].push({ id: incident.id, at: now })
    incident.suppressed = "rate_limited"
    return { accepted: true, note: "rate_limited", actions: [] }
  }
  // A held incident posted now is no longer held.
  desk.meta.held[route] = desk.meta.held[route].filter((h) => h.id !== incident.id)
  incident.suppressed = undefined
  incident.queued = true
  desk.meta.posted.push({ at: now, reporter: incident.reporter.key, route })
  // The same person and Mac again soon after (the app came back, still unreachable; or its link kept
  // dropping): a reply in the first message's thread.
  const parent = Object.values(desk.incidents)
    .filter(
      (i) =>
        i.id !== incident.id &&
        !i.parent &&
        i.queued &&
        i.route === route &&
        i.reporter.key === incident.reporter.key &&
        i.report.mac.id === report.mac.id &&
        now - i.updatedAt <= THREAD_WINDOW_MS
    )
    .sort((a, b) => b.updatedAt - a.updatedAt)[0]
  const text = render(incident, report, desk, now, { announceHeld: true })
  desk.meta.held[route] = []
  if (parent) {
    incident.parent = parent.id
    parent.updatedAt = now
    return { accepted: true, actions: [{ kind: "post", incident: incident.id, route, text: `Again: ${text}`, thread: parent.id }] }
  }
  return { accepted: true, actions: [{ kind: "post", incident: incident.id, route, text }] }
}

/** How long an incident may stay open with no end from the phone (killed and never relaunched, removed). */
export const OPEN_EXPIRY_MS = 3 * HOUR

/** When the next open incident expires, if any. */
export const nextExpiry = (desk: DeskState): number | undefined => {
  const due = Object.values(desk.incidents)
    .filter((i) => i.queued && !i.expired && !i.states.some((s) => s !== "open"))
    .map((i) => i.receivedAt + OPEN_EXPIRY_MS)
  return due.length ? Math.min(...due) : undefined
}

/**
 * Closes the messages of incidents whose end never came (the app was closed for good or removed), so none
 * says "and counting" forever. An end that arrives later still edits the message.
 */
export const expireStale = (desk: DeskState, now: number): { actions: Array<SlackAction>; changed: Array<string> } => {
  const actions: Array<SlackAction> = []
  const changed: Array<string> = []
  for (const incident of Object.values(desk.incidents)) {
    if (!incident.queued || incident.expired || incident.states.some((s) => s !== "open")) continue
    if (now - incident.receivedAt < OPEN_EXPIRY_MS) continue
    incident.expired = true
    incident.updatedAt = now
    changed.push(incident.id)
    const closed: IncidentReport = {
      ...incident.report,
      state: "ended",
      endReason: "no_end_reported",
      observedAt: new Date(now).toISOString(),
      durationMs: now - Date.parse(incident.report.startedAt)
    }
    const end = `No end arrived from the phone within ${duration(OPEN_EXPIRY_MS)} (the app was closed or removed); this incident is closed.`
    if (incident.parent) actions.push({ kind: "update", incident: incident.id, text: `Again: ${render(incident, closed, desk, now)}\n${end}`, thread: incident.parent })
    else actions.push({ kind: "update", incident: incident.id, text: render(incident, closed, desk, now) }, { kind: "reply", incident: incident.id, text: end })
  }
  return { actions, changed }
}

// MARK: Rendering

/** Escapes Slack's control characters in text that came from a phone. */
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

/** `2m 10s`, `45s`, `1h 3m`. */
export const duration = (ms: number): string => {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return s % 60 ? `${m}m ${s % 60}s` : `${m}m`
  const h = Math.floor(m / 60)
  return m % 60 ? `${h}h ${m % 60}m` : `${h}h`
}

const END_WORDS: Record<EndReason, string> = {
  app_backgrounded: "the app went to the background",
  network_lost: "the phone lost its network",
  mac_offline: "the Mac went offline",
  link_closed: "the app stopped using this Mac",
  signed_out: "the account signed out",
  app_relaunched: "the app was closed before it reconnected",
  no_end_reported: "no end arrived from the phone"
}

const TEST_WORDS: Record<TestReason, string> = {
  simulator: "simulator build",
  agent_account: "agent or service account",
  debug_build: "Debug build",
  network_simulation: "developer network simulation on"
}

const TRANSPORTS: Record<string, string> = { wireguard: "WireGuard", webrtc: "WebRTC" }

/** Other reporters with a Mac outage that started near this one: a sign the service, not the Mac. */
const othersAffected = (desk: DeskState, incident: Incident): number => {
  const reporters = new Set<string>()
  const start = Date.parse(incident.report.startedAt)
  for (const other of Object.values(desk.incidents)) {
    if (other.reporter.key === incident.reporter.key || other.route !== incident.route || other.report.kind !== "mac_unreachable") continue
    if (other.suppressed && other.suppressed !== "rate_limited") continue
    if (Math.abs(Date.parse(other.report.startedAt) - start) <= CORRELATION_WINDOW_MS) reporters.add(other.reporter.key)
  }
  return reporters.size
}

const headline = (incident: Incident, report: IncidentReport): string => {
  const who = esc(incident.reporter.email)
  const mac = `“${esc(report.mac.name)}”`
  const unreachable = report.kind === "mac_unreachable"
  switch (report.state) {
    case "open":
      return unreachable
        ? `:red_circle: *${who} can't reach Mac ${mac}* — down ${duration(report.durationMs)} and counting`
        : `:large_orange_circle: *${who}'s link to Mac ${mac} keeps dropping* — ${report.drops ?? "several"} drops in ${duration(report.durationMs)}`
    case "resolved":
      return unreachable
        ? `:large_green_circle: *${who} couldn't reach Mac ${mac}* — reconnected after ${duration(report.durationMs)}`
        : `:large_green_circle: *${who}'s link to Mac ${mac} kept dropping* — stable again after ${duration(report.durationMs)}`
    case "ended":
      return unreachable
        ? `:white_circle: *${who} couldn't reach Mac ${mac}* for ${duration(report.durationMs)} — never reconnected (${END_WORDS[report.endReason!]})`
        : `:white_circle: *${who}'s link to Mac ${mac} kept dropping* for ${duration(report.durationMs)} — ended (${END_WORDS[report.endReason!]})`
  }
}

/** The whole message for `incident` in the state `report` describes. */
export const render = (incident: Incident, report: IncidentReport, desk: DeskState, now: number, opts: { announceHeld?: boolean } = {}): string => {
  const lines = [headline(incident, report)]
  if (report.kind === "mac_unreachable" && report.serviceReachable === false)
    lines.push("• :warning: The phone could not reach the cmux service either (the internet worked): likely a cmux service outage")
  const others = othersAffected(desk, incident)
  if (others > 0) lines.push(`• :rotating_light: ${others} other teammate${others === 1 ? "" : "s"} lost a Mac within 10 minutes of this: likely service-side`)
  const tried: Array<string> = []
  if (report.attempts !== undefined) tried.push(`${report.attempts} dial${report.attempts === 1 ? "" : "s"}`)
  if (report.lastError) tried.push(`last error: \`${esc(report.lastError).replace(/`/g, "'")}\``)
  if (tried.length) lines.push(`• ${tried.join(" · ")}`)
  const where = [
    report.transport ? (TRANSPORTS[report.transport] ?? esc(report.transport)) : undefined,
    report.network ? esc(report.network) : undefined,
    `${esc(report.device.model)} · iOS ${esc(report.device.os)}`,
    `cmux ${esc(report.app.version)} (${esc(report.app.build)}) ${esc(report.app.config)}`
  ].filter(Boolean)
  lines.push(`• ${where.join(" · ")}`)
  if (report.simulations?.length) lines.push(`• Developer network simulation on: ${report.simulations.join(", ")}`)
  const late = now - Date.parse(report.observedAt)
  if (late > LATE_MS) lines.push(`• Delivered ${duration(late)} late (the phone queued it)`)
  const held = heldInHour(desk, incident.route, now).filter((h) => h.id !== incident.id).length
  if (opts.announceHeld && held > 0)
    lines.push(`• ${held} more incident${held === 1 ? " was" : "s were"} held back in the last hour (rate limit)`)
  if (incident.route === "test") lines.push(`• _Test route: ${TEST_WORDS[incident.why ?? "agent_account"]}_`)
  lines.push(`_Incident \`${incident.id.slice(0, 8)}\` · started <!date^${Math.floor(Date.parse(report.startedAt) / 1000)}^{date_short_pretty} {time_secs}|${report.startedAt}> · Mac \`${esc(report.mac.id.slice(0, 8))}\`_`)
  return lines.join("\n")
}

const endLine = (report: IncidentReport): string =>
  report.state === "resolved"
    ? `Resolved: ${report.kind === "mac_unreachable" ? "reconnected" : "stable again"} after ${duration(report.durationMs)}.`
    : `Ended without reconnecting after ${duration(report.durationMs)}: ${END_WORDS[report.endReason!]}.`

// MARK: Slack

export interface SlackConfig {
  readonly token: string
  readonly teamChannel?: string
  readonly testChannel?: string
}

export const slackConfig = (env: Env): SlackConfig | undefined =>
  env.SLACK_BOT_TOKEN ? { token: env.SLACK_BOT_TOKEN, teamChannel: env.CONNECTIVITY_ALERT_CHANNEL || undefined, testChannel: env.CONNECTIVITY_ALERT_TEST_CHANNEL || undefined } : undefined

/** One Slack Web API call; `ok:false` with Slack's error, or a thrown network error. */
export type SlackCall = (method: "chat.postMessage" | "chat.update", body: Record<string, unknown>) => Promise<{ ok: boolean; ts?: string; channel?: string; error?: string }>

export const slackCaller =
  (token: string, fetcher: typeof fetch = fetch): SlackCall =>
  async (method, body) => {
    const res = await fetcher(`https://slack.com/api/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8", authorization: `Bearer ${token}` },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000)
    })
    if (res.status === 429) return { ok: false, error: "ratelimited" }
    if (!res.ok) return { ok: false, error: `http_${res.status}` }
    return (await res.json()) as { ok: boolean; ts?: string; channel?: string; error?: string }
  }

/**
 * Whether a failed Slack call can pass with time: Slack or the network down, or rate limiting. Anything else
 * (a bad channel, a revoked token, an error Slack adds later) is dropped and logged rather than retried, so
 * one bad call never holds up every alert behind it.
 */
export const retryable = (error: string | undefined): boolean =>
  !!error && (error.startsWith("network:") || /^http_5\d\d$/.test(error) || ["ratelimited", "internal_error", "fatal_error", "service_unavailable", "request_timeout"].includes(error))

// MARK: The Durable Object

/** Retry delays for a Slack call that failed for a reason that can pass (seconds; the last repeats). */
const RETRY_S = [5, 30, 120, 600, 1800]
/** A call that keeps failing for a passing reason is retried as long as its incident is kept, then dropped (logged). */
const MAX_AGE_MS = RETENTION_MS

interface Outbox {
  action: SlackAction
  tries: number
  at: number
}

/**
 * The one desk (named "desk"): each incident under its own key for a week, the hourly counts, and an
 * ordered outbox of Slack calls. A report is stored before it is answered, and its Slack calls run in order
 * after the answer; one that fails for a passing reason (Slack down, rate limited) is retried by alarm, so an
 * accepted report is never lost to a Slack hiccup.
 */
export class ConnectivityAlertDesk extends DurableObject<Env> {
  /** Test only: replaces the Slack call (ENVIRONMENT=test). */
  static testSlack: SlackCall | undefined

  private async loadDesk(): Promise<DeskState> {
    const meta = normalizeMeta(await this.ctx.storage.get<Partial<DeskMeta>>("meta"))
    const incidents: Record<string, Incident> = {}
    for (const [key, incident] of await this.ctx.storage.list<Incident>({ prefix: "inc:" })) incidents[key.slice(4)] = incident
    return { incidents, meta }
  }

  private async outbox(): Promise<Array<Outbox>> {
    return (await this.ctx.storage.get<Array<Outbox>>("outbox")) ?? []
  }

  /** Applies a verified report; its Slack calls are queued before this returns and sent after. */
  async report(report: IncidentReport, reporter: Reporter, audience: { route: "team" | "test"; why?: TestReason }, check: MacCheck): Promise<{ accepted: boolean; note?: string; queued: number }> {
    const desk = await this.loadDesk()
    const outcome = applyReport(desk, report, reporter, audience, check, Date.now())
    const outbox = await this.outbox()
    for (const action of outcome.actions) outbox.push({ action, tries: 0, at: Date.now() })
    const writes: Record<string, unknown> = { meta: desk.meta, outbox }
    for (const id of outcome.changed) if (desk.incidents[id]) writes[`inc:${id}`] = desk.incidents[id]
    await this.ctx.storage.put(writes)
    if (outcome.removed.length) await this.ctx.storage.delete(outcome.removed.map((id) => `inc:${id}`))
    console.log(JSON.stringify({ msg: "connectivity report", kind: report.kind, state: report.state, route: audience.route, note: outcome.note ?? "posted", queued: outcome.actions.length }))
    // After the answer: a slow Slack must not make the phone's request time out and resend.
    const retryAt = (await this.ctx.storage.get<number>("retryAt")) ?? 0
    if (outbox.length && retryAt <= Date.now()) this.ctx.waitUntil(this.drain())
    await this.scheduleAlarm(desk)
    return { accepted: outcome.accepted, ...(outcome.note ? { note: outcome.note } : {}), queued: outcome.actions.length }
  }

  /** Test only: the desk and outbox as stored. */
  async snapshot(): Promise<{ desk: DeskState; outbox: Array<Outbox> }> {
    return { desk: await this.loadDesk(), outbox: await this.outbox() }
  }

  /** Test only: waits for a drain in flight. */
  async settled(): Promise<void> {
    await this.draining
  }

  /** Retries the Slack outbox when its wait is over, and closes incidents whose end never came. */
  async alarm(): Promise<void> {
    const now = Date.now()
    const retryAt = (await this.ctx.storage.get<number>("retryAt")) ?? 0
    if (retryAt <= now) await this.ctx.storage.delete("retryAt")
    const desk = await this.loadDesk()
    const expired = expireStale(desk, now)
    if (expired.actions.length) {
      const outbox = await this.outbox()
      for (const action of expired.actions) outbox.push({ action, tries: 0, at: now })
      const writes: Record<string, unknown> = { outbox }
      for (const id of expired.changed) writes[`inc:${id}`] = desk.incidents[id]
      await this.ctx.storage.put(writes)
      console.log(JSON.stringify({ msg: "connectivity incidents expired", count: expired.changed.length }))
    }
    if (retryAt <= now) await this.drain()
    await this.scheduleAlarm(await this.loadDesk())
  }

  /** One alarm for whichever comes first: the outbox's retry or the next open incident's expiry. */
  private async scheduleAlarm(desk: DeskState): Promise<void> {
    const retryAt = await this.ctx.storage.get<number>("retryAt")
    const candidates = [retryAt, nextExpiry(desk)].filter((t): t is number => typeof t === "number")
    if (!candidates.length) return
    const at = Math.min(...candidates)
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > at || current < Date.now()) await this.ctx.storage.setAlarm(at)
  }

  /** Test only: closes stale incidents as if `now` were the time (the alarm uses the clock). */
  async expireAt(now: number): Promise<number> {
    const desk = await this.loadDesk()
    const expired = expireStale(desk, now)
    const outbox = await this.outbox()
    for (const action of expired.actions) outbox.push({ action, tries: 0, at: now })
    const writes: Record<string, unknown> = { outbox }
    for (const id of expired.changed) writes[`inc:${id}`] = desk.incidents[id]
    await this.ctx.storage.put(writes)
    await this.drain()
    return expired.changed.length
  }

  private draining: Promise<void> | undefined

  private drain(): Promise<void> {
    this.draining ??= this.drainOnce().finally(() => {
      this.draining = undefined
    })
    return this.draining
  }

  /**
   * Sends the outbox in order; stops at the first passing failure and sets an alarm for its retry. Reports
   * can arrive while a Slack call is in flight, so after each call the state is read again and only the
   * delivered head (and its message id) is changed.
   */
  private async drainOnce(): Promise<void> {
    const config = slackConfig(this.env)
    const call = ConnectivityAlertDesk.testSlack ?? (config ? slackCaller(config.token) : undefined)
    for (;;) {
      const head = (await this.outbox())[0]
      if (!head) return
      if (!call) {
        console.log(JSON.stringify({ msg: "connectivity alert not sent: Slack is not configured", kind: head.action.kind }))
        await this.ctx.storage.setAlarm(Date.now() + 600_000)
        return
      }
      const incident = await this.ctx.storage.get<Incident>(`inc:${head.action.incident}`)
      const result = await this.send(head.action, incident, config, call).catch((e) => ({ ok: false as const, error: `network: ${String(e).slice(0, 80)}` }))
      const outbox = await this.outbox()
      const giveUp = !result.ok && (!retryable(result.error) || Date.now() - head.at > MAX_AGE_MS)
      if (result.ok || giveUp) {
        if (giveUp) console.log(JSON.stringify({ msg: "connectivity alert dropped", kind: head.action.kind, error: result.error, tries: head.tries + 1 }))
        outbox.shift()
        const writes: Record<string, unknown> = { outbox }
        if (result.ok && "posted" in result && result.posted) {
          const fresh = await this.ctx.storage.get<Incident>(`inc:${head.action.incident}`)
          if (fresh) writes[`inc:${head.action.incident}`] = { ...fresh, slack: result.posted }
        }
        await this.ctx.storage.put(writes)
        continue
      }
      outbox[0]!.tries += 1
      const tries = outbox[0]!.tries
      const wait = RETRY_S[Math.min(tries - 1, RETRY_S.length - 1)]!
      await this.ctx.storage.put({ outbox, retryAt: Date.now() + wait * 1000 })
      console.log(JSON.stringify({ msg: "connectivity alert retry", kind: head.action.kind, error: result.error, tries, waitS: wait }))
      await this.ctx.storage.setAlarm(Date.now() + wait * 1000)
      return
    }
  }

  /** One Slack call; a post returns the message it made. */
  private async send(
    action: SlackAction,
    incident: Incident | undefined,
    config: SlackConfig | undefined,
    call: SlackCall
  ): Promise<{ ok: boolean; error?: string; posted?: { channel: string; ts: string } }> {
    if (!incident) return { ok: true }
    const threadOf = async (id: string | undefined) => (id ? (await this.ctx.storage.get<Incident>(`inc:${id}`))?.slack : undefined)
    switch (action.kind) {
      case "post": {
        const channel = action.route === "team" ? config?.teamChannel : config?.testChannel
        if (!channel) {
          console.log(JSON.stringify({ msg: "connectivity alert has no channel", route: action.route }))
          return { ok: true }
        }
        const parent = await threadOf(action.thread)
        // A thread whose first message was never posted (dropped): this one stands on its own.
        const where = parent ? { channel: parent.channel, thread_ts: parent.ts } : { channel }
        const r = await call("chat.postMessage", { ...where, text: action.text, unfurl_links: false, unfurl_media: false })
        return r.ok && r.ts ? { ok: true, posted: { channel: r.channel ?? where.channel, ts: r.ts } } : { ok: r.ok, ...(r.error ? { error: r.error } : {}) }
      }
      case "update": {
        if (incident.slack) return call("chat.update", { channel: incident.slack.channel, ts: incident.slack.ts, text: action.text })
        const parent = await threadOf(action.thread)
        if (!parent) return { ok: true }
        return call("chat.postMessage", { channel: parent.channel, thread_ts: parent.ts, text: action.text, unfurl_links: false })
      }
      case "reply": {
        if (!incident.slack) return { ok: true }
        return call("chat.postMessage", { channel: incident.slack.channel, thread_ts: incident.slack.ts, text: action.text, unfurl_links: false })
      }
    }
  }
}
