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

export const securityNotice = (
  env: { readonly user: string; readonly locale?: string; readonly email?: string | null },
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
  return [
    { kind: "feed.post", entity: `notice:${key}`, payload: { type: "notice", kind: "notice", title, body, priority: "high" }, target: { class: "FeedDO", name: env.user } },
    // Only to a verified address; without one the feed notice is the only one.
    ...(env.email
      ? [{
          kind: "mail.security_notice",
          entity: `mail:${key}`,
          payload: { user: env.user, to: env.email, template: `text_confirm_${kind}`, locale, title, body, install: info.install, at: info.at },
          target: { class: SECURITY_MAIL_TARGET, name: env.user }
        }]
      : [])
  ]
}
