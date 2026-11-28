import { invites } from "@cmux/home-core"
import { authenticate } from "./auth.ts"
import type { Env } from "./env.ts"
import { PRODUCTION_WORKER, sendSwitchOn } from "./home-send.ts"

/**
 * The mail a chat share invite sends ("Alice shared a chat with you", with the chat's invite link),
 * the way a shared doc mails its new reader. The cmux daemon decides whether a mail is due (an
 * email account that no live share of the chat invited yet: never an `@handle`, a repeat invite or
 * a role change; cmux-tui agent_session_share_mail.rs) and calls this route with the owner's cmux
 * token; this route only delivers, through the Home invites sender (`deliverInvite`).
 *
 *   POST /v1/share-invites/mail {to, invite_url, role?}  (bearer: the share owner's session or install token)
 *        -> 200 {state, provider_id}  (state: sent, disabled, refused_env, suppressed, indeterminate)
 *        400 share_invite_mail.bad_request, 401 auth.unauthenticated, 404 share_invite_mail.off,
 *        429 share_invite_mail.rate_limited (10 per minute per user), 502 share_invite_mail.failed,
 *        503 share_invite_mail.unavailable (no rate limiter bound)
 *
 * Fail-closed switches: SHARE_INVITE_MAIL_SEND must be exactly "on" (unset, the default
 * everywhere, answers 404), and HOME_INVITES_SEND, the Home allow list outside production and the
 * Resend config (RESEND_API_KEY, HOME_INVITE_FROM) apply as for a Home invite. The link must be a
 * chat invite link (`/i/<share id>`) on this deployment's share host, and the sender's name comes
 * from the verified token, never the caller. A mail to the same person for the same share is sent
 * once (the Resend idempotency key derives from both). Every attempt logs one line without the
 * address, the link or the token.
 */
export const SHARE_INVITE_MAIL_PATH = "/v1/share-invites/mail"

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "referrer-policy": "no-referrer" } })
const failure = (code: string, message: string, status: number) => json({ error: { code, message } }, status)

/** Each deployment's chat share origins: its short share host and its platform origin (cmux-cloud-environment). */
const SHARE_ORIGINS: Readonly<Record<"production" | "staging" | "development", ReadonlyArray<string>>> = {
  production: ["https://share.cmux.dev", "https://cmux-platform-production.debussy.workers.dev"],
  staging: ["https://share-staging.cmux.dev", "https://cmux-platform-staging.debussy.workers.dev"],
  development: ["https://share-dev.cmux.dev", "https://cmux-platform-development.debussy.workers.dev"]
}

const EMAIL = /^[^\s@<>()",;:\\]+@[^\s@<>()",;:\\]+\.[^\s@<>()",;:\\]+$/
const SHARE_ID = /^\/i\/([A-Za-z0-9_-]{8,64})$/
const ROLES = new Set(["view", "talk", "drive"])

export const shareInviteMailOn = (env: Env) => env.SHARE_INVITE_MAIL_SEND === "on"

/** The environment whose policy applies: production only on the production Worker, as for Home invites. */
const environmentOf = (env: Env): invites.Environment => {
  const parsed = invites.parseEnvironment(env.ENVIRONMENT)
  return parsed === "production" && env.WORKER_NAME !== PRODUCTION_WORKER ? "staging" : parsed
}

/** The share id of an invite link on one of `environment`'s share origins, else null. */
export const shareIdOf = (environment: invites.Environment, link: string): string | null => {
  let url: URL
  try {
    url = new URL(link)
  } catch {
    return null
  }
  const deployment = environment === "production" ? "production" : environment === "staging" ? "staging" : "development"
  // Previews and local runs take staging's links too (their rooms are staging's or development's).
  const origins = deployment === "development" ? [...SHARE_ORIGINS.development, ...SHARE_ORIGINS.staging] : SHARE_ORIGINS[deployment]
  if (!origins.includes(url.origin) || url.search || url.hash || url.username || url.password) return null
  return SHARE_ID.exec(url.pathname)?.[1] ?? null
}

const roleWords = (role: string | undefined) => (role === "view" ? "view" : role === "drive" ? "work in" : "chat in")

/** The mail's copy. `name` is the verified inviter's, cleaned as user text. */
export const renderShareInviteEmail = (input: { readonly name: string; readonly link: string; readonly role?: string | undefined }): invites.RenderedEmail => {
  const name = invites.cleanUserText(input.name, 60, "[link removed]") || "Someone"
  const subject = `${name} shared a chat with you`
  const lead = `${name} shared a cmux chat with you and invited you to ${roleWords(input.role)} it.`
  const button = "Open the chat"
  const why = "You got this email because someone invited this address to a cmux chat. If you did not expect it, you can ignore it."
  const text = [lead, `\n${button}:\n${input.link}`, `\n--\n${why}`].join("\n")
  const e = invites.escapeHtml
  const html = [
    `<!doctype html><html lang="en"><body style="margin:0;padding:24px;background:#ffffff;color:#1d1d1f;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">`,
    `<div style="max-width:520px;margin:0 auto">`,
    `<p style="margin:0 0 24px">${e(lead)}</p>`,
    `<p style="margin:0 0 24px"><a href="${e(input.link)}" style="display:inline-block;padding:10px 18px;border-radius:10px;background:#1d1d1f;color:#ffffff;text-decoration:none;font-weight:600">${e(button)}</a></p>`,
    `<p style="margin:0;color:#86868b;font-size:12px">${e(why)}</p>`,
    `</div></body></html>`
  ].join("")
  return { channel: "email", variant: "A", subject, text, html, headers: {} }
}

const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("")

/** One id per share and recipient: the same invite again is the same Resend send. */
export const mailIdOf = async (shareId: string, to: string) =>
  `share-${hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${shareId}\n${to}`))).slice(0, 32)}`

export const handleShareInviteMail = async (
  request: Request,
  env: Env,
  fetcher: invites.Fetch = (url, init) => fetch(url, init as RequestInit)
): Promise<Response> => {
  if (request.method !== "POST") return failure("share_invite_mail.method", "use POST", 405)
  if (!shareInviteMailOn(env)) return failure("share_invite_mail.off", "share invite mail is off", 404)
  const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1]
  const principal = await authenticate(env, bearer)
  if (!principal?.user) return failure("auth.unauthenticated", "sign in to cmux", 401)
  if (!env.SHARE_INVITE_MAIL_LIMIT) return failure("share_invite_mail.unavailable", "share invite mail is unavailable", 503)
  const { success } = await env.SHARE_INVITE_MAIL_LIMIT.limit({ key: `share-invite-mail:${principal.user}` })
  if (!success) return failure("share_invite_mail.rate_limited", "too many share invite mails; try again in a minute", 429)
  let body: { to?: unknown; invite_url?: unknown; role?: unknown }
  try {
    body = (await request.json()) as typeof body
  } catch {
    return failure("share_invite_mail.bad_request", "send {to, invite_url, role?}", 400)
  }
  const to = typeof body?.to === "string" ? body.to.trim().toLowerCase() : ""
  const link = typeof body?.invite_url === "string" ? body.invite_url : ""
  const role = typeof body?.role === "string" && ROLES.has(body.role) ? body.role : undefined
  const environment = environmentOf(env)
  const shareId = shareIdOf(environment, link)
  if (to.length > 254 || !EMAIL.test(to) || !shareId || (body?.role !== undefined && !role)) {
    return failure("share_invite_mail.bad_request", "send an email address and a chat invite link", 400)
  }
  const log = (state: string, extra: Record<string, unknown> = {}) =>
    console.log(JSON.stringify({ msg: "share invite mail", at: new Date().toISOString(), env: env.ENVIRONMENT, user: principal.user, state, ...extra }))
  let allowlist: invites.Allowlist
  try {
    allowlist = invites.allowlistFromEnv(env.HOME_INVITE_ALLOWLIST_EMAILS, env.HOME_INVITE_ALLOWLIST_PHONES)
  } catch {
    log("refused_env", { reason: "allow list does not parse" })
    return json({ state: "refused_env", provider_id: null })
  }
  const deps: invites.SenderDeps = {
    policy: { environment, sendSwitch: sendSwitchOn(env) ? "on" : "off", allowlist, trustedInviter: false },
    fetch: fetcher,
    ...(env.RESEND_API_KEY && env.HOME_INVITE_FROM ? { resend: { apiKey: env.RESEND_API_KEY, from: env.HOME_INVITE_FROM } } : {})
  }
  const name = principal.display_name ?? (principal.email_verified ? principal.email : null) ?? "Someone"
  const message = renderShareInviteEmail({ name, link, role })
  const inviteId = await mailIdOf(shareId, to)
  const result = await invites.deliverInvite(deps, { inviteId, address: { channel: "email", value: to }, suppression: null, message })
  log(result.state, { mail: inviteId, allowlist_index: result.allowlist_index ?? 0, provider_id: result.provider_id ?? null, http_status: result.http_status ?? null, reason: result.reason ?? null })
  if (result.state === "failed") return failure("share_invite_mail.failed", "the mail was not sent", 502)
  return json({ state: result.state, provider_id: result.provider_id ?? null })
}
