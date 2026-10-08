import { createHash } from "node:crypto"
import type { OutboxItem } from "../conversation/engine-types.ts"
import copy from "../../copy/text-confirm-levels.json" with { type: "json" }
import type { ConfirmLevel } from "../mux/confirm-level.ts"

/**
 * Security notices for the text confirmation level: one feed item (FeedDO
 * pushes it to every device of the owner) and one email to the verified
 * address (sent by the owner's outbox drain through Resend), in the owner's locale. Never a text message: a
 * person who took over the number must not be the one who is told.
 */
type Strings = Readonly<Record<string, Readonly<Record<string, { readonly value: string }>>>>
const S = (copy as { strings: Strings }).strings

const t = (key: string, locale: string, vars: Readonly<Record<string, string>> = {}) => {
  const entry = S[`textConfirm.${key}`]
  const text = entry?.[locale]?.value ?? entry?.en?.value ?? key
  return text.replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? "")
}
const LEVEL_KEY: Readonly<Record<ConfirmLevel, string>> = { strict: "level.strict", "destructive-only": "level.destructiveOnly", off: "level.off" }

/** Outbox target class of the security email: not an object; the owner's drain sends it through Resend. */
export const SECURITY_MAIL_TARGET = "Mail"
/** At most one "presence key added" feed item and email per user in this window. */
export const KEY_ADDED_WINDOW_MS = 3_600_000

export interface NoticeEnv {
  readonly user: string
  readonly locale?: string
  /** Where security emails go: the verified address, plus for 14 days a previous verified one. */
  readonly emails?: ReadonlyArray<string>
}

/** One email per address (an address never sees another), keyed per address so retries stay idempotent. */
const securityMails = (env: NoticeEnv, key: string, coalesce: string | null, payload: Record<string, unknown>): Array<OutboxItem> =>
  [...new Set(env.emails ?? [])].map((to) => {
    const id = createHash("sha256").update(to).digest("base64url").slice(0, 16)
    return {
      kind: "mail.security_notice",
      entity: `mail:${key}:${id}`,
      payload: { ...payload, user: env.user, to },
      target: { class: SECURITY_MAIL_TARGET, name: env.user, ...(coalesce ? { coalesce: `mail:${coalesce}:${id}` } : {}) }
    }
  })

export const securityNotice = (
  env: NoticeEnv,
  kind: "lowered" | "key_added",
  seq: number,
  info: { readonly from?: ConfirmLevel; readonly to?: ConfirmLevel; readonly install: string; readonly at: number }
): ReadonlyArray<OutboxItem> => {
  const locale = env.locale ?? "en"
  const vars = { from: info.from ? t(LEVEL_KEY[info.from], locale) : "", to: info.to ? t(LEVEL_KEY[info.to], locale) : "" }
  const prefix = kind === "lowered" ? "lowered" : "keyAdded"
  const title = t(`${prefix}.title`, locale, vars)
  const body = t(`${prefix}.body`, locale, vars)
  const key = `${kind}:${env.user}:${seq}`
  // A new presence key needs no Face ID, so a broken or stolen client could add keys in a loop:
  // those notices collapse to one feed item and one email per user per hour (feed dedupe key,
  // outbox coalesce key, and the same Resend idempotency key). Each lowering needs a device proof
  // and keeps its own notice.
  const hourly = kind === "key_added" ? `${kind}:${env.user}:${Math.floor(info.at / KEY_ADDED_WINDOW_MS)}` : null
  const mailKey = hourly ?? key
  return [
    {
      kind: "feed.post",
      entity: `notice:${key}`,
      payload: { type: "notice", kind: "notice", title, body, priority: "high", ...(hourly ? { dedupe_key: hourly } : {}) },
      target: { class: "FeedDO", name: env.user }
    },
    // Only to verified addresses; without one the feed notice is the only one.
    ...securityMails(env, mailKey, hourly, { template: `text_confirm_${kind}`, locale, title, body, install: info.install, at: info.at })
  ]
}

/**
 * The account email changed (cx-44j.45): one feed item and one email to each previous verified
 * address still in its 14-day window (`env.emails` here holds only those, never the new address),
 * so the owner hears of a takeover that starts with an email change.
 */
export const emailChangedNotice = (env: NoticeEnv, at: number): ReadonlyArray<OutboxItem> => {
  const locale = env.locale ?? "en"
  const title = t("emailChanged.title", locale)
  const body = t("emailChanged.body", locale)
  const key = `email_changed:${env.user}:${at}`
  return [
    { kind: "feed.post", entity: `notice:${key}`, payload: { type: "notice", kind: "notice", title, body, priority: "high" }, target: { class: "FeedDO", name: env.user } },
    ...securityMails(env, key, null, { template: "email_changed", locale, title, body, at })
  ]
}
