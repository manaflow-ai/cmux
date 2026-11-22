import type { TargetItem } from "./do-outbox.ts"
import type { Env } from "./env.ts"

/**
 * Security notice email (H11, home-messaging.md section 21): when the text confirmation level is
 * lowered or a presence key is added, UserDO commits a `mail.security_notice` outbox item with
 * target class `Mail` (not an object). The owner's drain sends it here through Resend to the
 * user's verified address, with the item key as the provider idempotency key (a retried drain
 * never sends twice). Not configured, no address, or a refused request (4xx): `dead`, which the
 * drain drops at once with a logged reason (never retried). A rate limit, server error or network
 * error throws, which the drain counts as poison, so retries are capped (dead letter after
 * OUTBOX_MAX_ATTEMPTS, replayed a day later).
 */
export const SECURITY_MAIL_CLASS = "Mail"

export interface SecurityMailResult {
  readonly done: ReadonlyArray<number>
  readonly dead: ReadonlyArray<number>
  readonly reason?: string
}

interface MailParams {
  readonly to?: unknown
  readonly title?: unknown
  readonly body?: unknown
  readonly template?: unknown
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!)
const text = (v: unknown, max: number) => (typeof v === "string" && v.length > 0 && v.length <= max ? v : null)

export const deliverSecurityMail = async (env: Env, items: ReadonlyArray<TargetItem>, fetcher: typeof fetch = fetch): Promise<SecurityMailResult> => {
  if (!env.RESEND_API_KEY || !env.HOME_INVITE_FROM) return { done: [], dead: items.map((i) => i.id), reason: "mail.not_configured" }
  const done: Array<number> = []
  const dead: Array<number> = []
  for (const item of items) {
    const p = (item.params ?? {}) as MailParams
    const to = text(p.to, 320)
    const subject = text(p.title, 200)
    const body = text(p.body, 4000) ?? ""
    if (item.op !== "mail.security_notice" || !to || !to.includes("@") || !subject) {
      dead.push(item.id)
      continue
    }
    const res = await fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json", "Idempotency-Key": item.key },
      body: JSON.stringify({
        from: env.HOME_INVITE_FROM,
        to: [to],
        subject,
        text: body,
        html: `<p>${escapeHtml(body)}</p>`,
        tags: [{ name: "kind", value: "security_notice" }, { name: "template", value: String(text(p.template, 64) ?? "security_notice").replace(/[^A-Za-z0-9_-]/g, "_") }]
      })
    })
    if (res.ok) done.push(item.id)
    else if (res.status === 429 || res.status >= 500) throw new Error(`resend ${res.status}`)
    else dead.push(item.id)
  }
  return { done, dead }
}
