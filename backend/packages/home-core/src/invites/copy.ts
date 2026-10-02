import { STRINGS, type Locale, type Variant } from "./copy-strings.ts"

export type { Locale, Variant } from "./copy-strings.ts"

/**
 * Renders invite email and SMS from typed inputs (home-messaging.md section
 * 15). User-written text (inviter name, title, preview) is sanitized here:
 * control characters and URLs are removed, lengths are capped, HTML is
 * escaped. Variant A (the inviter's own words) needs a trusted inviter and a
 * preview; otherwise it falls back to B.
 */
export interface CopyInput {
  readonly variant: Variant
  readonly locale: Locale
  readonly inviterName: string
  readonly inviterEmail?: string | null
  readonly trustedInviter: boolean
  readonly kind: "dm" | "group"
  readonly title?: string | null
  readonly preview?: string | null
  readonly link: string
  /** One-click unsubscribe and report pages; omit only where those routes do not exist yet (no dead links). */
  readonly unsubscribeLink?: string | null
  readonly reportLink?: string | null
  /** The first text to this number carries the opt-out line (D-H5). */
  readonly firstSmsToNumber?: boolean
}

export interface RenderedEmail {
  readonly channel: "email"
  readonly variant: Variant
  readonly subject: string
  readonly text: string
  readonly html: string
  readonly headers: Readonly<Record<string, string>>
}

export interface RenderedSms {
  readonly channel: "sms"
  readonly variant: Variant
  readonly body: string
}

/**
 * Anything that could be read as a link: a scheme (`x://`, `mailto:`), `www.`,
 * or any word.letters pattern with ASCII or full-width dots (every TLD, so no
 * list to fall behind; the ideographic full stop is left alone because it ends
 * Japanese sentences). It removes whole whitespace-separated tokens.
 */
const URL_LIKE = /\S*(?:[a-z][a-z0-9+.-]*:\/\/|\bmailto:|\bwww[.．｡]|[\p{L}\p{N}][.．｡]+\p{L}{2,})\S*/giu

/** Removes control characters, collapses whitespace, removes URLs, caps the length (adds an ellipsis). */
export const cleanUserText = (value: string, max: number, linkRemoved: string): string => {
  const text = value
    .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩]/g, " ")
    .replace(URL_LIKE, linkRemoved)
    .replace(/\s+/g, " ")
    .trim()
  const chars = [...text]
  return chars.length <= max ? text : `${chars.slice(0, max - 1).join("").trimEnd()}…`
}

const fill = (template: string, values: Readonly<Record<string, string>>) => template.replace(/\{(\w+)\}/g, (_, k: string) => values[k] ?? "")

export const escapeHtml = (value: string) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")

interface Resolved {
  readonly variant: Variant
  readonly values: Readonly<Record<string, string>>
}

const resolve = (input: CopyInput, previewMax: number): Resolved => {
  const s = STRINGS[input.locale]
  const name = cleanUserText(input.inviterName, 40, "") || s.anonymous
  const preview = input.preview ? cleanUserText(input.preview, previewMax, s.linkRemoved) : ""
  const variant: Variant = input.variant === "A" && (!input.trustedInviter || !preview) ? "B" : input.variant
  // A group title is user text too: shown only for trusted inviters.
  const title = input.trustedInviter && input.title ? cleanUserText(input.title, 60, s.linkRemoved) || s.untitledGroup : s.untitledGroup
  return { variant, values: { name, preview, title, link: input.link } }
}

/**
 * The link is alone on the last line with nothing glued to it, so message apps
 * detect it and show a preview card; the opt-out line goes before it.
 */
export const renderSms = (input: CopyInput): RenderedSms => {
  const s = STRINGS[input.locale]
  const { variant, values } = resolve(input, 90)
  const v = s.variants[variant]
  const sentence = fill(input.kind === "dm" ? v.smsDm : v.smsGroup, values)
  const lines = [sentence, ...(input.firstSmsToNumber ? [s.smsOptOut] : []), checkedLink(input.link)]
  return { channel: "sms", variant, body: lines.join("\n") }
}

/** Only an absolute https URL with no whitespace may be the link line. */
const checkedLink = (link: string): string => {
  if (!/^https:\/\/[^\s]+$/.test(link)) throw new Error("invite link must be an absolute https URL")
  return link
}

export const renderEmail = (input: CopyInput): RenderedEmail => {
  const s = STRINGS[input.locale]
  const { variant, values } = resolve(input, 140)
  const v = s.variants[variant]
  const dm = input.kind === "dm"
  const subjectValues = { ...values, preview: cleanUserText(values.preview ?? "", 60, s.linkRemoved) }
  const subject = fill(dm ? v.subjectDm : v.subjectGroup, subjectValues)
  const lead = fill(dm ? v.leadDm : v.leadGroup, values)
  // A system value (the account's address), not user text: only control characters go.
  const email = input.inviterEmail ? input.inviterEmail.replace(/[\u0000-\u001f\u007f-\u009f\s]/g, "").slice(0, 254) : ""
  const why = email ? fill(s.whyWithEmail, { name: values.name!, email }) : fill(s.why, { name: values.name! })
  const quote = variant === "A" ? values.preview! : ""
  const text = [lead, quote ? `\n"${quote}"` : "", `\n${s.button}:\n${checkedLink(input.link)}`, `\n${s.what}`, `\n--\n${why}`, input.unsubscribeLink ? `${s.unsubscribe}: ${input.unsubscribeLink}` : "", input.reportLink ? `${s.report}: ${input.reportLink}` : ""]
    .filter(Boolean)
    .join("\n")
  const e = escapeHtml
  const html = [
    `<!doctype html><html lang="${input.locale}"><body style="margin:0;padding:24px;background:#ffffff;color:#1d1d1f;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">`,
    `<div style="max-width:520px;margin:0 auto">`,
    `<p style="margin:0 0 16px">${e(lead)}</p>`,
    quote ? `<p style="margin:0 0 20px;padding:12px 16px;border-radius:18px;background:#f2f2f2;white-space:pre-wrap">${e(quote)}</p>` : "",
    `<p style="margin:0 0 24px"><a href="${e(input.link)}" style="display:inline-block;padding:10px 18px;border-radius:10px;background:#1d1d1f;color:#ffffff;text-decoration:none;font-weight:600">${e(s.button)}</a></p>`,
    `<p style="margin:0 0 24px;color:#6e6e73;font-size:14px">${e(s.what)}</p>`,
    `<p style="margin:0;color:#86868b;font-size:12px">${e(why)}${footerLinks(input, s.unsubscribe, s.report)}</p>`,
    `</div></body></html>`
  ].join("")
  const headers: Record<string, string> = input.unsubscribeLink
    ? { "List-Unsubscribe": `<${input.unsubscribeLink}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" }
    : {}
  return { channel: "email", variant, subject, text, html, headers }
}

const footerLinks = (input: CopyInput, unsubscribe: string, report: string): string => {
  const links = [
    input.unsubscribeLink ? `<a href="${escapeHtml(input.unsubscribeLink)}" style="color:#86868b">${escapeHtml(unsubscribe)}</a>` : "",
    input.reportLink ? `<a href="${escapeHtml(input.reportLink)}" style="color:#86868b">${escapeHtml(report)}</a>` : ""
  ].filter(Boolean)
  return links.length ? `<br>${links.join(" · ")}` : ""
}
