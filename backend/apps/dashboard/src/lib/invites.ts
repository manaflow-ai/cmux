import { createServerFn } from "@tanstack/react-start"
import { getRequestHeader } from "@tanstack/react-start/server"
import { apiUrl, post, requireSameOrigin } from "./server"

/**
 * Invite landing (home-messaging.md section 5). The link is
 * `<origin>/i/<code>#<secret>`: link scanners and unfurlers never send the
 * fragment, so the server renders only code-level metadata (Open Graph) and
 * the browser sends the secret to the API when the person opens the invite.
 */
export const INVITE_CODE = /^[dg][0-9A-HJKMNP-TV-Z]{26}$/
export const INVITE_SECRET = /^[0-9A-HJKMNP-TV-Z]{26}$/

/** Public origin for absolute Open Graph URLs: CMUX_PUBLIC_ORIGIN, else this request's host. */
export const publicOrigin = createServerFn({ method: "GET" }).handler(async () => {
  const configured = process.env.CMUX_PUBLIC_ORIGIN
  if (configured) return configured.replace(/\/$/, "")
  const host = getRequestHeader("x-forwarded-host") ?? getRequestHeader("host") ?? "console.cmux.dev"
  return `https://${host}`
})

export type InvitePreview =
  | { readonly state: "ok"; readonly inviter: string; readonly kind: "dm" | "group"; readonly title?: string; readonly preview?: string }
  | { readonly state: "invalid" | "expired" | "not_ready" | "error"; readonly message: string }

/** Anonymous preview: anyone holding the secret may see who invited them (rate limited by the API). */
export const invitePreview = createServerFn({ method: "POST" })
  .validator((d: { code: string; secret: string }) => d)
  .handler(async ({ data }): Promise<InvitePreview> => {
    requireSameOrigin()
    if (!INVITE_CODE.test(data.code) || !INVITE_SECRET.test(data.secret)) return { state: "invalid", message: "This invite link is not complete. Open the whole link from your message." }
    const res = await fetch(`${apiUrl()}/v1/invites/preview`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: data.code, secret: data.secret })
    }).catch(() => undefined)
    if (!res) return { state: "error", message: "cmux could not be reached. Try again in a moment." }
    const body = (await res.json().catch(() => ({}))) as Record<string, unknown>
    if (res.ok) return body as InvitePreview
    if (res.status === 404 && body.code === undefined) return { state: "not_ready", message: "Invites are almost ready. Keep this message and open the link again soon." }
    if (body.code === "invite.expired") return { state: "expired", message: "This invite has expired. Ask the person who invited you to send a new one." }
    return { state: "invalid", message: "This invite is not valid. Ask the person who invited you to send a new one." }
  })

/** Accept with the signed-in Stack session; a signed-out person signs in first. */
export const inviteAccept = createServerFn({ method: "POST" })
  .validator((d: { code: string; secret: string; idempotency_key: string }) => d)
  .handler(async ({ data }) => {
    requireSameOrigin()
    if (!INVITE_CODE.test(data.code) || !INVITE_SECRET.test(data.secret)) return { ok: false as const, signedIn: true, message: "This invite link is not complete." }
    const r = await post<{ ok?: boolean; value?: { conversation?: string }; error?: { message?: string } }>("/v1/ops", {
      op: "invite.accept",
      params: { secret: data.secret, code: data.code },
      idempotency_key: data.idempotency_key,
      origin: "user"
    })
    if (r.status === 401) return { ok: false as const, signedIn: false, message: "Sign in to accept." }
    if (r.body.ok) return { ok: true as const, signedIn: true, conversation: r.body.value?.conversation ?? null }
    return { ok: false as const, signedIn: true, message: r.body.error?.message ?? "This invite could not be accepted yet." }
  })
