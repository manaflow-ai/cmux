import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"

/**
 * Connectivity alerts (PROTOCOL.md "Connectivity incidents"): a cmux team member's phone reports a major
 * connectivity incident (a Mac it could not reach for 30 s while everything else said it should, or a link
 * that kept dropping), and the cmux team's Slack channel hears about it once, with its end edited in.
 *
 * Who is heard is decided here, never by the phone: the reporter's verified Stack email must be on a team
 * domain, and agent or service accounts and simulators go to the test channel (or nowhere). The phone only
 * decides what is major, by rules it can see (CmuxMobileLive ConnectivityIncidentDetector).
 */

/** The cmux team's email domains (ConnectivityAudience.teamDomains on the phone; keep the two equal). */
export const TEAM_DOMAINS = ["manaflow.ai", "cmux.com", "manaflow.com"] as const

/** Team-domain accounts that are agents or services, not people: their phones never page the team. */
const DEFAULT_EXCLUDED = ["cmux-agent-development@manaflow.ai"]
const EXCLUDED_PREFIXES = ["cmux-agent-"]

/** Where a verified reporter's incidents go. */
export type Audience = { route: "team" } | { route: "test"; why: "simulator" | "agent_account" } | { route: "refuse"; why: "not_team" | "unverified" }

/** Whether `email`'s domain is a team domain, exactly or as a subdomain (look-alikes are not). */
export const isTeamEmail = (email: string): boolean => {
  const at = email.lastIndexOf("@")
  if (at <= 0) return false
  const domain = email.slice(at + 1).trim().toLowerCase()
  return TEAM_DOMAINS.some((team) => domain === team || domain.endsWith(`.${team}`))
}

/** Where a report from this account and build goes. `excluded` is the env's extra list (comma-separated). */
export const audienceOf = (email: string | null, verified: boolean, simulator: boolean, excluded = ""): Audience => {
  if (!email || !isTeamEmail(email)) return { route: "refuse", why: "not_team" }
  if (!verified) return { route: "refuse", why: "unverified" }
  const lower = email.trim().toLowerCase()
  const local = lower.slice(0, lower.lastIndexOf("@"))
  const list = [...DEFAULT_EXCLUDED, ...excluded.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean)]
  if (list.includes(lower) || EXCLUDED_PREFIXES.some((p) => local.startsWith(p))) return { route: "test", why: "agent_account" }
  if (simulator) return { route: "test", why: "simulator" }
  return { route: "team" }
}

// MARK: The report

export type IncidentKind = "mac_unreachable" | "link_unstable"
export type IncidentState = "open" | "resolved" | "ended"
/** How an incident ended without the Mac answering again. */
export type EndReason = "app_backgrounded" | "network_lost" | "mac_offline" | "link_closed" | "signed_out" | "app_relaunched"

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

const text = (v: unknown, field: string, max: number, required = true): string | undefined => {
  if (v === undefined || v === null) {
    if (required) throw new ReportError(`${field} is required`)
    return undefined
  }
  if (typeof v !== "string" || !v.trim()) throw new ReportError(`${field} must be a non-empty string`)
  // Slack control characters are escaped at render; length is bounded here.
  return v.trim().slice(0, max)
}
const date = (v: unknown, field: string): string => {
  const s = text(v, field, 40)!
  if (Number.isNaN(Date.parse(s))) throw new ReportError(`${field} must be an ISO 8601 date`)
  return new Date(Date.parse(s)).toISOString()
}
const count = (v: unknown, field: string, max: number): number | undefined => {
  if (v === undefined || v === null) return undefined
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0) throw new ReportError(`${field} must be a non-negative number`)
  return Math.min(Math.round(v), max)
}
const obj = (v: unknown, field: string): Record<string, unknown> => {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new ReportError(`${field} must be an object`)
  return v as Record<string, unknown>
}

/** The report in `body`, or a ReportError naming what is wrong. */
export const parseReport = (body: Record<string, unknown>): IncidentReport => {
  const id = text(body.id, "id", 64)!
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
  const device = obj(body.device, "device")
  const durationMs = count(body.durationMs, "durationMs", 30 * 86_400_000)
  if (durationMs === undefined) throw new ReportError("durationMs is required")
  const transport = text(body.transport, "transport", 32, false)
  const network = text(body.network, "network", 32, false)
  if (transport !== undefined && !WORD.test(transport)) throw new ReportError("transport must be one word")
  if (network !== undefined && !WORD.test(network)) throw new ReportError("network must be one word")
  if (body.serviceReachable !== undefined && typeof body.serviceReachable !== "boolean") throw new ReportError("serviceReachable must be a boolean")
  if (typeof app.simulator !== "boolean") throw new ReportError("app.simulator must be a boolean")
  const simulations = body.simulations === undefined ? undefined : body.simulations
  if (simulations !== undefined && (!Array.isArray(simulations) || !simulations.every((s) => typeof s === "string" && SIMULATIONS.has(s))))
    throw new ReportError("simulations must list relay_only or block_udp")
  const attempts = count(body.attempts, "attempts", 100_000)
  const drops = count(body.drops, "drops", 100_000)
  const lastError = text(body.lastError, "lastError", 300, false)
  return {
    id,
    kind,
    state,
    ...(endReason ? { endReason } : {}),
    startedAt: date(body.startedAt, "startedAt"),
    observedAt: date(body.observedAt, "observedAt"),
    durationMs,
    mac: { id: text(mac.id, "mac.id", 64)!, name: text(mac.name, "mac.name", 80)! },
    ...(attempts !== undefined ? { attempts } : {}),
    ...(drops !== undefined ? { drops } : {}),
    ...(lastError !== undefined ? { lastError } : {}),
    ...(transport !== undefined ? { transport } : {}),
    ...(typeof body.serviceReachable === "boolean" ? { serviceReachable: body.serviceReachable } : {}),
    ...(network !== undefined ? { network } : {}),
    app: { version: text(app.version, "app.version", 24)!, build: text(app.build, "app.build", 24)!, config: text(app.config, "app.config", 24)!, simulator: app.simulator },
    device: { model: text(device.model, "device.model", 48)!, os: text(device.os, "device.os", 24)! },
    ...(simulations?.length ? { simulations: simulations as Array<string> } : {})
  }
}

// MARK: The desk (pure): what each report does to Slack

/** Per-reporter and overall limits on new Slack threads, per sliding hour. */
export const LIMITS = { perReporterPerHour: 5, overallPerHour: 20 } as const
/** Reports of the same Mac outage from more teammates than one inside this window suggest the service. */
export const CORRELATION_WINDOW_MS = 10 * 60_000
/** How long an incident is remembered (so a late duplicate or end still finds its message). */
export const RETENTION_MS = 7 * 86_400_000

export interface Reporter {
  readonly key: string
  readonly email: string
}

export interface Incident {
  readonly id: string
  readonly route: "team" | "test"
  readonly reporter: Reporter
  readonly report: IncidentReport
  /** Every state seen, in arrival order (`open` first when it came). */
  readonly states: Array<IncidentState>
  readonly receivedAt: number
  /** The Slack message, once posted. */
  slack?: { channel: string; ts: string }
  /** Its post is queued (it may not be sent yet): later states edit that message rather than post again. */
  queued?: boolean
  /** Set when this incident's start was not posted because a limit was reached. */
  suppressed?: boolean
}

export interface DeskState {
  incidents: Record<string, Incident>
  /** New threads posted per route, by time (sliding-hour limits). */
  posted: Array<{ at: number; reporter: string; route: "team" | "test" }>
  /** Incidents not posted because of a limit, since the last post on that route. */
  suppressedSince: Record<"team" | "test", number>
}

export const emptyDesk = (): DeskState => ({ incidents: {}, posted: [], suppressedSince: { team: 0, test: 0 } })

/** One Slack call the desk wants made, in order. */
export type SlackAction =
  | { kind: "post"; incident: string; route: "team" | "test"; text: string }
  | { kind: "update"; incident: string; text: string }
  | { kind: "reply"; incident: string; text: string }

export interface DeskOutcome {
  readonly accepted: boolean
  /** Why nothing was sent (duplicate, rate_limited, ...), for the response and the log. */
  readonly note?: string
  readonly actions: ReadonlyArray<SlackAction>
}

const HOUR = 3_600_000

/**
 * Applies one verified report to the desk at `now`. Idempotent per (incident, state): a resend of a state
 * already seen changes nothing. An end of an incident whose start was never posted (it arrived after an
 * app relaunch, or the start hit a limit) still posts one message, so a major outage is never lost.
 */
export const applyReport = (desk: DeskState, report: IncidentReport, reporter: Reporter, route: "team" | "test", now: number): DeskOutcome => {
  desk.posted = desk.posted.filter((p) => now - p.at < HOUR)
  for (const [id, incident] of Object.entries(desk.incidents)) if (now - incident.receivedAt > RETENTION_MS) delete desk.incidents[id]

  const known = desk.incidents[report.id]
  if (known && known.reporter.key !== reporter.key) return { accepted: false, note: "foreign_incident", actions: [] }
  if (known?.states.includes(report.state)) return { accepted: true, note: "duplicate", actions: [] }
  // An incident ends once: a second ending (resolved after ended, or the other way) is a duplicate too.
  if (known && report.state !== "open" && known.states.some((s) => s !== "open")) return { accepted: true, note: "duplicate", actions: [] }
  // A start that arrives after its end (the phone's queue never reorders, but be safe) adds nothing.
  if (known && report.state === "open") return { accepted: true, note: "duplicate", actions: [] }

  if (known) {
    known.states.push(report.state)
    if (known.queued) {
      return { accepted: true, actions: [{ kind: "update", incident: known.id, text: render(known, report, desk, now, route) }, { kind: "reply", incident: known.id, text: endLine(report) }] }
    }
    // Its start was never posted (a limit): post the whole incident now, if the limits allow.
    return postNew(desk, known, report, route, now)
  }

  const incident: Incident = { id: report.id, route, reporter, report, states: [report.state], receivedAt: now }
  desk.incidents[report.id] = incident
  return postNew(desk, incident, report, route, now)
}

const postNew = (desk: DeskState, incident: Incident, report: IncidentReport, route: "team" | "test", now: number): DeskOutcome => {
  const mine = desk.posted.filter((p) => p.route === route && p.reporter === incident.reporter.key).length
  const all = desk.posted.filter((p) => p.route === route).length
  if (mine >= LIMITS.perReporterPerHour || all >= LIMITS.overallPerHour) {
    incident.suppressed = true
    desk.suppressedSince[route] += 1
    return { accepted: true, note: "rate_limited", actions: [] }
  }
  incident.suppressed = false
  incident.queued = true
  desk.posted.push({ at: now, reporter: incident.reporter.key, route })
  const text = render(incident, report, desk, now, route)
  desk.suppressedSince[route] = 0
  return { accepted: true, actions: [{ kind: "post", incident: incident.id, route, text }] }
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
  app_relaunched: "the app was closed before it reconnected"
}

const TRANSPORTS: Record<string, string> = { wireguard: "WireGuard", wireGuard: "WireGuard", webrtc: "WebRTC", webRTC: "WebRTC" }

/** Other reporters with a Mac outage that started near this one: a sign the service, not the Mac. */
const othersAffected = (desk: DeskState, incident: Incident): number => {
  const reporters = new Set<string>()
  const start = Date.parse(incident.report.startedAt)
  for (const other of Object.values(desk.incidents)) {
    if (other.reporter.key === incident.reporter.key || other.route !== incident.route || other.report.kind !== "mac_unreachable") continue
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

/** The whole message for `incident` in its newest state. */
export const render = (incident: Incident, report: IncidentReport, desk: DeskState, now: number, route: "team" | "test"): string => {
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
  if (late > 2 * 60_000) lines.push(`• Delivered ${duration(late)} late (the phone queued it)`)
  const suppressed = desk.suppressedSince[route]
  if (report.state === "open" && suppressed > 0) lines.push(`• ${suppressed} more incident${suppressed === 1 ? "" : "s"} in the last hour were not posted (rate limit)`)
  if (incident.route === "test") lines.push(`• _Test route: ${incident.report.app.simulator ? "simulator build" : "agent or service account"}_`)
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

/** Slack errors a retry cannot fix: the action is dropped (and logged) instead of retried forever. */
const PERMANENT = new Set(["channel_not_found", "not_in_channel", "invalid_auth", "account_inactive", "token_revoked", "missing_scope", "is_archived", "msg_too_long", "no_text", "cant_update_message", "message_not_found"])

// MARK: The Durable Object

/** Retry delays for a Slack call that failed for a reason that can pass (seconds; the last repeats). */
const RETRY_S = [5, 30, 120, 600, 1800]

interface Outbox {
  action: SlackAction
  tries: number
}

/**
 * The one desk (named "desk"): keeps every incident for a week, the hourly counts, and an outbox of Slack
 * calls. A report is stored before it is answered, and its Slack calls run in order from the outbox; a call
 * that fails for a passing reason (Slack down, rate limited) is retried by alarm, so an accepted report is
 * never lost to a Slack hiccup.
 */
export class ConnectivityAlertDesk extends DurableObject<Env> {
  /** Test only: replaces the Slack call (ENVIRONMENT=test). */
  static testSlack: SlackCall | undefined

  private async load(): Promise<{ desk: DeskState; outbox: Array<Outbox> }> {
    const desk = (await this.ctx.storage.get<DeskState>("desk")) ?? emptyDesk()
    const outbox = (await this.ctx.storage.get<Array<Outbox>>("outbox")) ?? []
    return { desk, outbox }
  }

  /** Applies a verified report; its Slack calls are queued before this returns, then sent. */
  async report(report: IncidentReport, reporter: Reporter, route: "team" | "test"): Promise<{ accepted: boolean; note?: string; queued: number }> {
    const { desk, outbox } = await this.load()
    const outcome = applyReport(desk, report, reporter, route, Date.now())
    for (const action of outcome.actions) outbox.push({ action, tries: 0 })
    await this.ctx.storage.put({ desk, outbox })
    if (outcome.note) console.log(JSON.stringify({ msg: "connectivity report", note: outcome.note, kind: report.kind, state: report.state, route }))
    // A Slack call waiting out its backoff is retried by the alarm, not sooner by the next report.
    const retryAt = (await this.ctx.storage.get<number>("retryAt")) ?? 0
    if (outbox.length && retryAt <= Date.now()) await this.drain()
    return { accepted: outcome.accepted, ...(outcome.note ? { note: outcome.note } : {}), queued: outcome.actions.length }
  }

  /** Test only: the desk as stored. */
  async snapshot(): Promise<{ desk: DeskState; outbox: Array<Outbox> }> {
    return this.load()
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.delete("retryAt")
    await this.drain()
  }

  private draining = false

  /**
   * Sends the outbox in order; stops at the first passing failure and sets an alarm for its retry. Reports
   * can arrive while a Slack call is in flight, so after each call the state is read again and only the
   * delivered head (and its message id) is changed.
   */
  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      const config = slackConfig(this.env)
      const call = ConnectivityAlertDesk.testSlack ?? (config ? slackCaller(config.token) : undefined)
      for (;;) {
        const before = await this.load()
        const next = before.outbox[0]
        if (!next) return
        if (!call) {
          console.log(JSON.stringify({ msg: "connectivity alert not sent: Slack is not configured", kind: next.action.kind }))
          await this.ctx.storage.setAlarm(Date.now() + 600_000)
          return
        }
        const result = await this.send(next.action, before.desk, config, call).catch((e) => ({ ok: false as const, error: `network: ${String(e).slice(0, 80)}` }))
        const { desk, outbox } = await this.load()
        if (result.ok || PERMANENT.has(result.error ?? "")) {
          if (!result.ok) console.log(JSON.stringify({ msg: "connectivity alert dropped", kind: next.action.kind, error: result.error }))
          const incident = desk.incidents[next.action.incident]
          if (result.ok && result.posted && incident) incident.slack = result.posted
          outbox.shift()
          await this.ctx.storage.put({ desk, outbox })
          continue
        }
        outbox[0]!.tries += 1
        const tries = outbox[0]!.tries
        await this.ctx.storage.put({ outbox })
        const wait = RETRY_S[Math.min(tries - 1, RETRY_S.length - 1)]!
        console.log(JSON.stringify({ msg: "connectivity alert retry", kind: next.action.kind, error: result.error, tries, waitS: wait }))
        await this.ctx.storage.put("retryAt", Date.now() + wait * 1000)
        await this.ctx.storage.setAlarm(Date.now() + wait * 1000)
        return
      }
    } finally {
      this.draining = false
    }
  }

  /** One Slack call; a post returns the message it made. */
  private async send(action: SlackAction, desk: DeskState, config: SlackConfig | undefined, call: SlackCall): Promise<{ ok: boolean; error?: string; posted?: { channel: string; ts: string } }> {
    const incident = desk.incidents[action.incident]
    if (!incident) return { ok: true }
    switch (action.kind) {
      case "post": {
        const channel = action.route === "team" ? config?.teamChannel : config?.testChannel
        if (!channel) {
          console.log(JSON.stringify({ msg: "connectivity alert has no channel", route: action.route }))
          return { ok: true }
        }
        const r = await call("chat.postMessage", { channel, text: action.text, unfurl_links: false, unfurl_media: false })
        return r.ok && r.ts ? { ok: true, posted: { channel: r.channel ?? channel, ts: r.ts } } : { ok: r.ok, ...(r.error ? { error: r.error } : {}) }
      }
      case "update": {
        if (!incident.slack) return { ok: true }
        return call("chat.update", { channel: incident.slack.channel, ts: incident.slack.ts, text: action.text })
      }
      case "reply": {
        if (!incident.slack) return { ok: true }
        return call("chat.postMessage", { channel: incident.slack.channel, thread_ts: incident.slack.ts, text: action.text, unfurl_links: false })
      }
    }
  }
}
