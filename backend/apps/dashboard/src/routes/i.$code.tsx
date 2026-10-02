import { createFileRoute, Link } from "@tanstack/react-router"
import { useState, useSyncExternalStore } from "react"
import { INVITE_CODE, inviteAccept, invitePreview, publicOrigin, type InvitePreview } from "../lib/invites"
import { saveReturnPath } from "../lib/return-path"

const TITLE = "You're invited to chat on cmux"
const DESCRIPTION = "Join the conversation with people and their AI chiefs. Open the link to see who invited you."

export const Route = createFileRoute("/i/$code")({
  loader: async () => ({ origin: await publicOrigin() }),
  head: ({ loaderData, params }) => {
    const origin = loaderData?.origin ?? "https://console.cmux.dev"
    const url = `${origin}/i/${INVITE_CODE.test(params.code) ? params.code : ""}`
    const image = `${origin}/og/invite.png`
    return {
      meta: [
        { title: TITLE },
        { name: "description", content: DESCRIPTION },
        { property: "og:type", content: "website" },
        { property: "og:site_name", content: "cmux" },
        { property: "og:title", content: TITLE },
        { property: "og:description", content: DESCRIPTION },
        { property: "og:url", content: url },
        { property: "og:image", content: image },
        { property: "og:image:width", content: "1200" },
        { property: "og:image:height", content: "630" },
        { property: "og:image:alt", content: "cmux: you're invited to chat with people and AI chiefs" },
        { name: "twitter:card", content: "summary_large_image" },
        { name: "twitter:title", content: TITLE },
        { name: "twitter:description", content: DESCRIPTION },
        { name: "twitter:image", content: image },
        // Invite pages are personal: keep them out of search results.
        { name: "robots", content: "noindex, nofollow" },
        { name: "referrer", content: "no-referrer" }
      ]
    }
  },
  component: InvitePage
})

/** The fragment (the secret) exists only in the browser; the server render sees "". */
const subscribeHash = (cb: () => void) => {
  window.addEventListener("hashchange", cb)
  return () => window.removeEventListener("hashchange", cb)
}
const useSecret = () => useSyncExternalStore(subscribeHash, () => window.location.hash.replace(/^#/, ""), () => "")

function InvitePage() {
  const { code } = Route.useParams()
  const secret = useSecret()
  const [preview, setPreview] = useState<InvitePreview | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const validCode = INVITE_CODE.test(code)

  const open = async () => {
    setBusy(true)
    setPreview(await invitePreview({ data: { code, secret } }).catch(() => ({ state: "error" as const, message: "cmux could not be reached. Try again in a moment." })))
    setBusy(false)
  }

  const accept = async () => {
    setBusy(true)
    const r = await inviteAccept({ data: { code, secret, idempotency_key: `accept:${code}:${secret.slice(0, 8)}` } }).catch(() => ({ ok: false as const, signedIn: true, message: "cmux could not be reached." }))
    setBusy(false)
    if (r.ok) return setStatus("You joined the conversation. Open cmux on your Mac or iPhone to reply.")
    if (!r.signedIn) {
      saveReturnPath(`/i/${code}#${secret}`)
      return window.location.assign("/")
    }
    setStatus(r.message)
  }

  return (
    <div className="card" style={{ maxWidth: 480, margin: "40px auto" }}>
      <h2 style={{ marginTop: 0 }}>{TITLE}</h2>
      {!validCode || !secret ? (
        <p className="error">This invite link is not complete. Open the whole link from your message (it ends with a # and a code).</p>
      ) : preview === null ? (
        <>
          <p className="muted">{DESCRIPTION}</p>
          <button onClick={open} disabled={busy}>
            {busy ? "Opening…" : "Open the invite"}
          </button>
        </>
      ) : preview.state === "ok" ? (
        <>
          <p>
            <strong>{preview.inviter}</strong> invited you to {preview.kind === "dm" ? "a conversation" : `the group ${preview.title ?? ""}`}.
          </p>
          {preview.preview ? <blockquote className="muted">{preview.preview}</blockquote> : null}
          <button onClick={accept} disabled={busy}>
            {busy ? "Joining…" : "Accept and join"}
          </button>
        </>
      ) : (
        <p className={preview.state === "not_ready" ? "muted" : "error"}>{preview.message}</p>
      )}
      {status ? <p>{status}</p> : null}
      <p className="muted" style={{ fontSize: 12, marginTop: 24 }}>
        cmux is a terminal and workspace for people and their AI agents. <Link to="/">Sign in</Link>
      </p>
    </div>
  )
}
