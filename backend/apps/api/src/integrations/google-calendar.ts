import { ProviderError, type ProviderImpl } from "./provider-core.ts"
import { googleApi, googleAuthorizeUrl, googleComplete, googleConfigured, googleRefresh, oauthToken, refuseGoogleScopes } from "./google.ts"

/**
 * Google Calendar provider (sensitive scopes only: verification, no CASA).
 * Events are read at call time and returned; nothing is stored.
 */

const CAL = "https://www.googleapis.com/calendar/v3"
const ALLOWED = ["calendar.events", "calendar.calendarlist.readonly"]
const SCOPES: Record<string, ReadonlyArray<string>> = {
  "calendar.calendars.list": ["calendar.calendarlist.readonly"],
  "calendar.events.list": ["calendar.events"],
  "calendar.event.create": ["calendar.events"],
  "calendar.event.respond": ["calendar.events"]
}

type When = { date_time?: string; date?: string; time_zone?: string }
type GEvent = {
  id?: string
  status?: string
  summary?: string
  description?: string
  location?: string
  htmlLink?: string
  hangoutLink?: string
  recurringEventId?: string
  start?: { dateTime?: string; date?: string; timeZone?: string }
  end?: { dateTime?: string; date?: string; timeZone?: string }
  organizer?: { email?: string; self?: boolean }
  attendees?: Array<{ email?: string; responseStatus?: string; self?: boolean; optional?: boolean; organizer?: boolean }>
}

const toGoogle = (w: When, field: string) => {
  if ((w.date_time === undefined) === (w.date === undefined)) throw new ProviderError("provider.error", `${field} needs exactly one of date_time and date`)
  return { ...(w.date_time ? { dateTime: w.date_time } : { date: w.date }), ...(w.time_zone ? { timeZone: w.time_zone } : {}) }
}
const fromGoogle = (w: GEvent["start"]) => ({ ...(w?.dateTime ? { date_time: w.dateTime } : {}), ...(w?.date ? { date: w.date } : {}), ...(w?.timeZone ? { time_zone: w.timeZone } : {}) })

export const eventView = (e: GEvent) => ({
  id: e.id,
  status: e.status,
  summary: e.summary ?? "",
  ...(e.description ? { description: e.description } : {}),
  ...(e.location ? { location: e.location } : {}),
  start: fromGoogle(e.start),
  end: fromGoogle(e.end),
  ...(e.htmlLink ? { html_link: e.htmlLink } : {}),
  ...(e.hangoutLink ? { meet_link: e.hangoutLink } : {}),
  ...(e.recurringEventId ? { recurring_event_id: e.recurringEventId } : {}),
  ...(e.organizer?.email ? { organizer: e.organizer.email } : {}),
  attendees: (e.attendees ?? []).map((a) => ({ email: a.email, response: a.responseStatus, ...(a.self ? { self: true } : {}), ...(a.optional ? { optional: true } : {}) }))
})

const cal = (v: unknown) => encodeURIComponent(typeof v === "string" ? v : "primary")

export const googleCalendar: ProviderImpl = {
  configured: googleConfigured,
  defaultScopes: ["calendar.events", "calendar.calendarlist.readonly"],
  refuseScopes: refuseGoogleScopes(ALLOWED),
  authorizeUrl: googleAuthorizeUrl,
  complete: googleComplete("google_calendar"),
  refresh: googleRefresh,
  scopesFor: (op) => SCOPES[op],
  call: async (_env, http, credential, op, params) => {
    const token = oauthToken(credential)
    switch (op) {
      case "calendar.calendars.list": {
        const b = await googleApi(http, token, "GET", `${CAL}/users/me/calendarList?maxResults=250`, { what: "calendarList.list" })
        const items = (b.items ?? []) as Array<{ id?: string; summary?: string; primary?: boolean; accessRole?: string; timeZone?: string }>
        return { value: { calendars: items.map((c) => ({ id: c.id, summary: c.summary ?? "", primary: c.primary === true, access_role: c.accessRole, time_zone: c.timeZone })) } }
      }
      case "calendar.events.list": {
        const q = new URLSearchParams({ singleEvents: "true", orderBy: "startTime", maxResults: String(params.max_results ?? 50) })
        for (const [k, g] of [["time_min", "timeMin"], ["time_max", "timeMax"], ["query", "q"], ["page_token", "pageToken"]] as const) if (typeof params[k] === "string") q.set(g, params[k] as string)
        const b = await googleApi(http, token, "GET", `${CAL}/calendars/${cal(params.calendar_id)}/events?${q}`, { what: "events.list" })
        return { value: { events: ((b.items ?? []) as Array<GEvent>).map(eventView), ...(typeof b.nextPageToken === "string" ? { next_page_token: b.nextPageToken } : {}) } }
      }
      case "calendar.event.create": {
        const p = params as { summary: string; description?: string; location?: string; start: When; end: When; attendees?: Array<string> }
        const attendees = p.attendees ?? []
        const body = {
          summary: p.summary,
          ...(p.description ? { description: p.description } : {}),
          ...(p.location ? { location: p.location } : {}),
          start: toGoogle(p.start, "start"),
          end: toGoogle(p.end, "end"),
          ...(attendees.length ? { attendees: attendees.map((email) => ({ email })) } : {})
        }
        const b = await googleApi(http, token, "POST", `${CAL}/calendars/${cal(params.calendar_id)}/events?sendUpdates=${attendees.length ? "all" : "none"}`, { body, effect: true, what: "events.insert" })
        return { value: { id: b.id, html_link: b.htmlLink } }
      }
      case "calendar.event.respond": {
        const url = `${CAL}/calendars/${cal(params.calendar_id)}/events/${encodeURIComponent(String(params.event_id))}`
        const e = (await googleApi(http, token, "GET", url, { what: "events.get" })) as GEvent
        const attendees = e.attendees ?? []
        if (!attendees.some((a) => a.self)) throw new ProviderError("provider.error", "the connected account is not an attendee of this event")
        // Only the own attendee row changes; Google needs the full list in a patch.
        const next = attendees.map((a) => (a.self ? { ...a, responseStatus: params.response } : a))
        await googleApi(http, token, "PATCH", `${url}?sendUpdates=all`, { body: { attendees: next }, effect: true, what: "events.patch" })
        return { value: { id: e.id, response: params.response } }
      }
      default:
        throw new ProviderError("provider.error", `google calendar cannot run ${op}`)
    }
  }
}
