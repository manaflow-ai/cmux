import { ProviderError, type ProviderImpl } from "./provider-core.ts"
import { googleApi, googleAuthorizeUrl, googleComplete, googleConfigured, googleRefresh, googleGrantKeys, googleRevoke, oauthToken, refuseGoogleScopes, restrictedScopesEnabled } from "./google.ts"

/**
 * Gmail provider (S2, S3). Reads return content at call time only; nothing
 * here stores a subject, sender, snippet or body. Sending builds a plain-text
 * RFC 5322 message; header values are already free of CR and LF (protocol
 * schema), so a parameter cannot add a header.
 */

const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
const ALLOWED = ["gmail.send", "gmail.readonly", "gmail.modify"]
/** Plain text returned per message; longer bodies are cut and flagged. */
export const MAX_TEXT_CHARS = 100_000
const PEEK_CONCURRENCY = 8

const READ = ["gmail.readonly", "gmail.modify"]
const SCOPES: Record<string, ReadonlyArray<string>> = {
  "mail.send": ["gmail.send", "gmail.modify"],
  "mail.search": READ,
  "mail.get": READ,
  "mail.thread.get": READ,
  "mail.threads.peek": READ,
  "mail.modify": ["gmail.modify"]
}

const enc = new TextEncoder()
const b64 = (bytes: Uint8Array) => {
  let s = ""
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}
const b64url = (bytes: Uint8Array) => b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const fromB64url = (s: string) => {
  const t = s.replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(t + "=".repeat((4 - (t.length % 4)) % 4)), (c) => c.charCodeAt(0))
}

/**
 * A header value: printable ASCII as is (folded before 998 characters), else
 * RFC 2047 encoded words of at most 45 UTF-8 bytes (75 characters each), cut
 * only between characters and folded onto continuation lines.
 */
export const headerValue = (v: string) => {
  // Printable ASCII stays one line; the schema caps the subject at 900 characters, under the 998 line limit.
  if (/^[\x20-\x7e]*$/.test(v)) return v
  const words: Array<string> = []
  let chunk: Array<number> = []
  for (const ch of v) {
    const bytes = enc.encode(ch)
    if (chunk.length + bytes.length > 45) {
      words.push(`=?UTF-8?B?${b64(Uint8Array.from(chunk))}?=`)
      chunk = []
    }
    chunk.push(...bytes)
  }
  if (chunk.length) words.push(`=?UTF-8?B?${b64(Uint8Array.from(chunk))}?=`)
  return words.join("\r\n ")
}

export const buildMime = (p: { to: ReadonlyArray<string>; cc?: ReadonlyArray<string>; bcc?: ReadonlyArray<string>; subject: string; body: string; in_reply_to?: string }): string => {
  const lines = [`To: ${p.to.join(", ")}`]
  if (p.cc?.length) lines.push(`Cc: ${p.cc.join(", ")}`)
  if (p.bcc?.length) lines.push(`Bcc: ${p.bcc.join(", ")}`)
  lines.push(`Subject: ${headerValue(p.subject)}`)
  if (p.in_reply_to) lines.push(`In-Reply-To: ${p.in_reply_to}`, `References: ${p.in_reply_to}`)
  lines.push("MIME-Version: 1.0", 'Content-Type: text/plain; charset="UTF-8"', "Content-Transfer-Encoding: base64", "")
  const body = b64(enc.encode(p.body)).replace(/(.{76})/g, "$1\r\n")
  return `${lines.join("\r\n")}\r\n${body}`
}

const HEADERS = ["from", "to", "cc", "subject", "date", "message-id", "in-reply-to", "references"]

type Part = { mimeType?: string; filename?: string; headers?: Array<{ name?: string; value?: string }>; body?: { data?: string; attachmentId?: string; size?: number }; parts?: Array<Part> }
type Message = { id?: string; threadId?: string; labelIds?: Array<string>; snippet?: string; internalDate?: string; historyId?: string; payload?: Part }

const headersOf = (part: Part | undefined) => {
  const out: Record<string, string> = {}
  for (const h of part?.headers ?? []) {
    const name = String(h.name ?? "").toLowerCase()
    if (HEADERS.includes(name) && out[name] === undefined) out[name] = String(h.value ?? "")
  }
  return out
}

const walk = (part: Part | undefined, visit: (p: Part) => void) => {
  if (!part) return
  visit(part)
  for (const c of part.parts ?? []) walk(c, visit)
}

/** Message fields for a caller, built at call time and returned, never stored. */
export const messageView = (m: Message, full: boolean) => {
  const base = {
    id: m.id,
    thread_id: m.threadId,
    label_ids: m.labelIds ?? [],
    snippet: m.snippet ?? "",
    internal_date: Number(m.internalDate ?? 0),
    headers: headersOf(m.payload)
  }
  if (!full) return base
  let text = ""
  let hasHtml = false
  const attachments: Array<{ attachment_id: string; filename: string; mime_type: string; size: number }> = []
  walk(m.payload, (p) => {
    // A part with a file name is an attachment, never body text (inline data included).
    if (p.filename) {
      if (p.body?.attachmentId) attachments.push({ attachment_id: p.body.attachmentId, filename: p.filename, mime_type: p.mimeType ?? "application/octet-stream", size: p.body.size ?? 0 })
    } else if (p.mimeType === "text/plain" && p.body?.data && text.length < MAX_TEXT_CHARS) text += new TextDecoder().decode(fromB64url(p.body.data))
    else if (p.mimeType === "text/html") hasHtml = true
  })
  const cut = text.length > MAX_TEXT_CHARS
  return { ...base, text: cut ? text.slice(0, MAX_TEXT_CHARS) : text, ...(cut ? { text_truncated: true } : {}), has_html: hasHtml, attachments }
}

const id = (v: unknown) => encodeURIComponent(String(v))

export const gmail: ProviderImpl = {
  configured: googleConfigured,
  // Read scopes are asked for only where the deployment may use them (plan G1).
  defaultScopes: (env) => (restrictedScopesEnabled(env) ? ["gmail.send", "gmail.modify"] : ["gmail.send"]),
  refuseScopes: refuseGoogleScopes(ALLOWED),
  authorizeUrl: googleAuthorizeUrl,
  complete: googleComplete("gmail"),
  refresh: googleRefresh,
  revoke: googleRevoke,
  grantKeys: googleGrantKeys,
  scopesFor: (op) => SCOPES[op],
  call: async (_env, http, credential, op, params) => {
    const token = oauthToken(credential)
    switch (op) {
      case "mail.send": {
        const p = params as { to: Array<string>; cc?: Array<string>; bcc?: Array<string>; subject: string; body: string; thread_id?: string; in_reply_to?: string }
        const raw = b64url(enc.encode(buildMime(p)))
        const b = await googleApi(http, token, "POST", `${GMAIL}/messages/send`, { body: { raw, ...(p.thread_id ? { threadId: p.thread_id } : {}) }, effect: true, what: "messages.send" })
        return { value: { id: b.id, thread_id: b.threadId } }
      }
      case "mail.search": {
        const q = new URLSearchParams({ q: String(params.query ?? ""), maxResults: String(params.max_results ?? 25) })
        if (typeof params.page_token === "string") q.set("pageToken", params.page_token)
        const b = await googleApi(http, token, "GET", `${GMAIL}/messages?${q}`, { what: "messages.list" })
        const messages = ((b.messages ?? []) as Array<{ id?: string; threadId?: string }>).map((m) => ({ id: m.id, thread_id: m.threadId }))
        return { value: { messages, ...(typeof b.nextPageToken === "string" ? { next_page_token: b.nextPageToken } : {}), result_size_estimate: Number(b.resultSizeEstimate ?? messages.length) } }
      }
      case "mail.get": {
        const b = await googleApi(http, token, "GET", `${GMAIL}/messages/${id(params.message_id)}?format=full`, { what: "messages.get" })
        return { value: messageView(b as Message, true) }
      }
      case "mail.thread.get": {
        const b = await googleApi(http, token, "GET", `${GMAIL}/threads/${id(params.thread_id)}?format=full`, { what: "threads.get" })
        const messages = ((b.messages ?? []) as Array<Message>).slice(-50).map((m) => messageView(m, true))
        return { value: { id: b.id, messages } }
      }
      case "mail.threads.peek": {
        const ids = params.thread_ids as Array<string>
        const rows: Array<unknown> = new Array(ids.length)
        let next = 0
        const worker = async () => {
          for (let i = next++; i < ids.length; i = next++) {
            const q = "format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date"
            try {
              const t = await googleApi(http, token, "GET", `${GMAIL}/threads/${id(ids[i])}?${q}`, { what: "threads.get" })
              const msgs = (t.messages ?? []) as Array<Message>
              const last = msgs.at(-1)
              const first = headersOf(msgs[0]?.payload)
              const labels = [...new Set(msgs.flatMap((m) => m.labelIds ?? []))].sort()
              rows[i] = { thread_id: ids[i], subject: first.subject ?? "", from: headersOf(last?.payload).from ?? "", date: Number(last?.internalDate ?? 0), snippet: last?.snippet ?? "", message_count: msgs.length, unread: labels.includes("UNREAD"), labels }
            } catch (e) {
              if (e instanceof ProviderError && e.status === 404) rows[i] = { thread_id: ids[i], missing: true }
              else throw e
            }
          }
        }
        await Promise.all(Array.from({ length: Math.min(PEEK_CONCURRENCY, ids.length) }, worker))
        return { value: { threads: rows } }
      }
      case "mail.modify": {
        const p = params as { thread_id?: string; message_ids?: Array<string>; add_labels?: Array<string>; remove_labels?: Array<string>; archive?: boolean }
        if ((p.thread_id === undefined) === (p.message_ids === undefined)) throw new ProviderError("provider.error", "mail.modify needs exactly one of thread_id and message_ids")
        const remove = [...new Set([...(p.remove_labels ?? []), ...(p.archive ? ["INBOX"] : [])])]
        const add = [...new Set(p.add_labels ?? [])]
        if (add.length === 0 && remove.length === 0) throw new ProviderError("provider.error", "mail.modify changes nothing")
        const body = { addLabelIds: add, removeLabelIds: remove }
        if (p.thread_id) await googleApi(http, token, "POST", `${GMAIL}/threads/${id(p.thread_id)}/modify`, { body, effect: true, what: "threads.modify" })
        else await googleApi(http, token, "POST", `${GMAIL}/messages/batchModify`, { body: { ids: p.message_ids, ...body }, effect: true, what: "messages.batchModify" })
        return { value: { ok: true, added: add, removed: remove } }
      }
      default:
        throw new ProviderError("provider.error", `gmail cannot run ${op}`)
    }
  }
}
