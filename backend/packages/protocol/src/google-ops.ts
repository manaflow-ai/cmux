import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { ConnectionId } from "./integrations.ts"

/**
 * Google Calendar and Gmail ops (spec integrations.md "APIs and ops", D14,
 * S2, S3; plans/cmux-next/integrations-plan.md G1). The gateway (the owner
 * team's ConnectionDO) holds the token and makes the call; reads return
 * content at call time and nothing is stored (S2). Gmail reads need a
 * restricted scope, which a deployment asks for only after the CASA step.
 */

const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))
/** One header line: no CR or LF, so a value cannot add a header (header injection). */
const HeaderText = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max), Schema.isPattern(/^[^\r\n]*$/))
const Email = Schema.String.check(Schema.isMaxLength(254), Schema.isPattern(/^[^\s@<>,;:"\\()\[\]]+@[^\s@<>,;:"\\()\[\]]+\.[^\s@<>,;:"\\()\[\]]+$/)).annotate({
  identifier: "EmailAddress"
})
const Recipients = (max: number) => Schema.Array(Email).check(Schema.isMaxLength(max))
/** Gmail message, thread and label ids (opaque; restricted to URL-safe characters). */
const GmailId = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{1,64}$/))
const LabelId = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{1,100}$/))
const CalendarId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(254), Schema.isPattern(/^(?!\.{1,2}$)[^\s/?#%]+$/))
const EventId = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{1,1024}$/))
const PageToken = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2000))
const Rfc3339 = Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})$/))
const When = Schema.Struct({
  /** A timed event: RFC 3339 with an offset. */
  date_time: Schema.optionalKey(Rfc3339),
  /** An all-day event: YYYY-MM-DD. */
  date: Schema.optionalKey(Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/))),
  time_zone: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(64), Schema.isPattern(/^[A-Za-z0-9_+/-]+$/)))
})

const errors = [...mutationErrors, "selector.not_found", "integration.unavailable", "provider.error", "mutation.indeterminate", "policy.denied"]
const readErrors = ["auth.unauthenticated", "auth.forbidden", "selector.not_found", "integration.unavailable", "provider.error", "policy.denied"]

const mutation = <P extends Schema.Top>(name: string, risk: CloudOpDef["risk"], params: P, docs: string) =>
  def({
    name,
    owner: "cloud:ConnectionDO",
    class: "mutation",
    risk,
    target: "connection",
    principals: ["session", "install"],
    params,
    result: Schema.Unknown,
    errors,
    docs,
    cli: { path: name.replace(/\./g, " "), visible: true },
    mcp: { expose: "default", group: name.split(".")[0]! }
  })

const read = <P extends Schema.Top>(name: string, params: P, docs: string) =>
  def({
    name,
    owner: "cloud:ConnectionDO",
    class: "read",
    risk: "read",
    target: "connection",
    principals: ["session", "install"],
    params,
    result: Schema.Unknown,
    errors: readErrors,
    docs,
    cli: { path: name.replace(/\./g, " "), visible: true },
    mcp: { expose: "default", group: name.split(".")[0]! }
  })

// ---------------------------------------------------------------- Google Calendar

export const CalendarCalendarsList = read("calendar.calendars.list", Schema.Struct({ connection: ConnectionId }), "List the calendars of a Google Calendar connection (ids for the other calendar ops).")

export const CalendarEventsList = read(
  "calendar.events.list",
  Schema.Struct({
    connection: ConnectionId,
    calendar_id: Schema.optionalKey(CalendarId),
    time_min: Schema.optionalKey(Rfc3339),
    time_max: Schema.optionalKey(Rfc3339),
    query: Schema.optionalKey(Text(500)),
    max_results: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 250 }))),
    page_token: Schema.optionalKey(PageToken)
  }),
  "List events of a Google calendar (single events, ordered by start). Read at call time; nothing is stored."
)

export const CalendarEventCreate = mutation(
  "calendar.event.create",
  // With attendees Google mails invitations, so the op is send-external even without them.
  "send-external",
  Schema.Struct({
    connection: ConnectionId,
    calendar_id: Schema.optionalKey(CalendarId),
    summary: Text(1024),
    description: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(8000))),
    location: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(1024))),
    start: When,
    end: When,
    attendees: Schema.optionalKey(Recipients(100))
  }),
  "Create a Google Calendar event; attendees get Google's invitation email."
)

export const CalendarEventRespond = mutation(
  "calendar.event.respond",
  "send-external",
  Schema.Struct({
    connection: ConnectionId,
    calendar_id: Schema.optionalKey(CalendarId),
    event_id: EventId,
    response: Schema.Literals(["accepted", "declined", "tentative"])
  }),
  "Answer a Google Calendar invitation as the connected account; the organizer is notified."
)

// ---------------------------------------------------------------- Gmail

export const MailSend = mutation(
  "mail.send",
  "send-external",
  Schema.Struct({
    connection: ConnectionId,
    to: Recipients(100).check(Schema.isMinLength(1)),
    cc: Schema.optionalKey(Recipients(100)),
    bcc: Schema.optionalKey(Recipients(100)),
    subject: HeaderText(900),
    body: Schema.String.check(Schema.isMaxLength(1_000_000)),
    /** Gmail thread to add the message to (a reply). */
    thread_id: Schema.optionalKey(GmailId),
    /** RFC 5322 Message-ID of the message replied to, for example `<abc@mail.example.com>`. */
    in_reply_to: Schema.optionalKey(HeaderText(998).check(Schema.isPattern(/^<[^<>\s]+>$/)))
  }),
  "Send a plain-text email from the connected Gmail account."
)

export const MailSearch = read(
  "mail.search",
  Schema.Struct({
    connection: ConnectionId,
    query: Schema.String.check(Schema.isMaxLength(2000)),
    max_results: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 100 }))),
    page_token: Schema.optionalKey(PageToken)
  }),
  "Search the connected Gmail mailbox with Gmail query syntax; returns message and thread ids only."
)

export const MailGet = read("mail.get", Schema.Struct({ connection: ConnectionId, message_id: GmailId }), "Read one Gmail message (headers, plain text, attachment list) at call time; nothing is stored.")

export const MailThreadGet = read("mail.thread.get", Schema.Struct({ connection: ConnectionId, thread_id: GmailId }), "Read one Gmail thread (every message, as mail.get) at call time; nothing is stored.")

export const MailThreadsPeek = read(
  "mail.threads.peek",
  Schema.Struct({ connection: ConnectionId, thread_ids: Schema.Array(GmailId).check(Schema.isMinLength(1), Schema.isMaxLength(50)) }),
  "Row data for Gmail threads (subject, sender, date, snippet, unread) by id, for feed rows; held in client memory only."
)

export const MailModify = mutation(
  "mail.modify",
  "mutate-own",
  Schema.Struct({
    connection: ConnectionId,
    /** Exactly one of thread_id and message_ids. */
    thread_id: Schema.optionalKey(GmailId),
    message_ids: Schema.optionalKey(Schema.Array(GmailId).check(Schema.isMinLength(1), Schema.isMaxLength(1000))),
    add_labels: Schema.optionalKey(Schema.Array(LabelId).check(Schema.isMaxLength(100))),
    remove_labels: Schema.optionalKey(Schema.Array(LabelId).check(Schema.isMaxLength(100))),
    /** Removes the INBOX label. */
    archive: Schema.optionalKey(Schema.Boolean)
  }),
  "Change labels of Gmail messages or a thread (archive, mark read with remove_labels UNREAD)."
)

export const googleOps = [CalendarCalendarsList, CalendarEventsList, CalendarEventCreate, CalendarEventRespond, MailSend, MailSearch, MailGet, MailThreadGet, MailThreadsPeek, MailModify] as const

/** Google ops with an effect: run in the ConnectionDO's external-effect ledger. */
export const googleProviderOpNames: ReadonlySet<string> = new Set(googleOps.filter((d) => d.class === "mutation").map((d) => d.name))
/** Google reads: no idempotency key, no effect. */
export const googleReadOpNames: ReadonlySet<string> = new Set(googleOps.filter((d) => d.class === "read").map((d) => d.name))
