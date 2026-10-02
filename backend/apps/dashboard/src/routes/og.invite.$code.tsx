import { createFileRoute } from "@tanstack/react-router"
import { INVITE_CODE } from "../lib/invites"
import { renderInviteCard, type InviteCard } from "../lib/invite-card"

/**
 * GET /og/invite/<code>.png: the per-invite thumbnail for iMessage and other unfurlers.
 * Public and cacheable (it shows only the inviter's first name and avatar). The code is the
 * same public part of the link the unfurler already has; the secret is never involved.
 */
const FIRST_NAME = /^[\p{L}\p{M}' .-]{1,40}$/u

const loadCard = async (code: string): Promise<InviteCard | null> => {
  const api = process.env.CMUX_API_URL
  if (!api) return null
  try {
    const res = await fetch(`${api.replace(/\/$/, "")}/v1/invites/card/${code}`, { signal: AbortSignal.timeout(2500) })
    if (!res.ok) return null
    const body = (await res.json()) as { first_name?: unknown; avatar_url?: unknown }
    if (typeof body.first_name !== "string" || !FIRST_NAME.test(body.first_name)) return null
    const avatar = typeof body.avatar_url === "string" ? await avatarDataUrl(body.avatar_url) : null
    return { first_name: body.first_name.trim(), avatar_url: avatar }
  } catch {
    return null
  }
}

/**
 * The avatar is fetched here (https only, 2.5 s, at most 1 MB, PNG or JPEG) and embedded as a
 * data URL, so the renderer never fetches a remote URL itself. Any failure drops the avatar
 * (the card shows the initial).
 */
const avatarDataUrl = async (url: string): Promise<string | null> => {
  if (!url.startsWith("https://") || url.length > 1024) return null
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(2500), redirect: "follow" })
    const type = (res.headers.get("content-type") ?? "").split(";")[0]!.trim()
    if (!res.ok || !["image/png", "image/jpeg"].includes(type)) return null
    const bytes = new Uint8Array(await res.arrayBuffer())
    if (bytes.byteLength > 1_000_000) return null
    let bin = ""
    for (const b of bytes) bin += String.fromCharCode(b)
    return `data:${type};base64,${btoa(bin)}`
  } catch {
    return null
  }
}

export const Route = createFileRoute("/og/invite/$code")({
  server: {
    handlers: {
      GET: async ({ params, request }) => {
        const code = params.code.replace(/\.png$/, "")
        const card = INVITE_CODE.test(code) ? await loadCard(code) : null
        const png = await renderInviteCard(card, new URL(request.url).origin)
        return new Response(png as Uint8Array<ArrayBuffer>, {
          status: 200,
          headers: {
            "Content-Type": "image/png",
            // Personalized cards change rarely; the generic fallback refreshes soon so a card
            // appears once the API knows the invite.
            "Cache-Control": card ? "public, max-age=86400, s-maxage=86400" : "public, max-age=300, s-maxage=300"
          }
        })
      }
    }
  }
})
