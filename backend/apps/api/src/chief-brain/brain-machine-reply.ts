import type { Principal } from "@cmux/ownership"
import type { conversation } from "@cmux/home-core"
import { apiOrigin } from "../hand-api.ts"
import { sha256Hex } from "../hand-wire.ts"
import { handleAttachmentIntent, handleAttachmentUpload, handleAttachmentMultipartPart, handleAttachmentMultipartComplete } from "../home-attachments.ts"
import type { ChiefBrainDO } from "./brain-do.ts"
import { writeConfig } from "./brain-store.ts"

/** One message stays under the conversation's text bound; a larger result is a complete file. */
const INLINE_BYTES = 60 * 1024
type Attachment = conversation.AttachmentPart
type Upload = { state: "upload"; mode: "stream" | "multipart"; upload_url: string; expires_at: number; slot?: string; part_size?: number; part_count?: number }
type Receipt = { state: "stored" | "exists"; attachment: Omit<Attachment, "type" | "name"> }
const stored = (b: ChiefBrainDO, key: string): string | undefined => b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, key).toArray()[0]?.value

const read = async <T>(response: Response): Promise<T> => {
  const body = await response.json() as { ok: boolean; value?: T; error?: { code?: string; retry_after_ms?: unknown } }
  if (!response.ok || !body.ok || body.value === undefined) {
    const wait = body.error?.retry_after_ms
    const code = body.error?.code
    throw Object.assign(new Error("chief.machine.reply_storage_pending"), { code, ...(code === "archived" || code === "auth.forbidden" ? { refusal: code } : {}), retryAfterMs: typeof wait === "number" && Number.isFinite(wait) && wait > 0 ? wait : 60_000 })
  }
  return body.value
}

/** Only links present in the result are shown; the complete text remains available in its file. */
const compact = (reply: string): string => {
  let text = "The full result is attached."
  const seen = new Set<string>()
  for (const match of reply.matchAll(/https?:\/\/[^\s<>"'`]+/g)) {
    const candidate = match[0].replace(/[)\]},.;!?]+$/, "")
    try {
      const url = new URL(candidate)
      if (url.username || url.password || seen.has(candidate)) continue
      seen.add(candidate)
      const next = `${text}\n\n${candidate}`
      if (new TextEncoder().encode(next).length <= INLINE_BYTES) text = next
    } catch { /* Unparseable text is preserved in the attachment. */ }
  }
  return text
}

/** Uses the existing participant, quota, upload verification and attachment admission paths. */
export const prepareMachineReply = async (b: ChiefBrainDO, id: string, conversation: string, reply: string, principal: Principal): Promise<{ text: string; attachment?: Attachment }> => {
  const bytes = new TextEncoder().encode(reply)
  if (bytes.length <= INLINE_BYTES) return { text: reply }
  const hash = await sha256Hex(reply), name = `chief-${id}-result.txt`
  const artifactKey = `machine-reply-artifact:${id}`, planKey = `machine-reply-upload:${id}`
  const previous = stored(b, artifactKey)
  if (previous) {
    const attachment = JSON.parse(previous) as Attachment
    if (attachment.hash !== hash || attachment.byte_count !== bytes.length) throw new Error("chief.machine.reply_changed")
    return { text: compact(reply), attachment }
  }
  const origin = apiOrigin(b.doEnv)
  const request = (path: string, body: unknown) => new Request(`${origin}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
  const save = (attachment: Omit<Attachment, "type" | "name">) => {
    if (attachment.hash !== hash || attachment.byte_count !== bytes.length || attachment.mime_type !== "text/plain") throw new Error("chief.machine.reply_changed")
    const part: Attachment = { type: "attachment", name, ...attachment }
    writeConfig(b.sql, { [artifactKey]: JSON.stringify(part) })
    b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, planKey)
    return { text: compact(reply), attachment: part }
  }
  const savedPlan = stored(b, planKey)
  let upload = savedPlan ? JSON.parse(savedPlan) as Upload : undefined
  if (!upload || upload.expires_at <= Date.now()) {
    const intent = await read<Upload | Receipt>(await handleAttachmentIntent(request("/v1/home/attachments/intent", { conversation, sha256: hash, byte_count: bytes.length, mime_type: "text/plain", name, multipart: true }), b.doEnv, undefined, principal))
    if (intent.state !== "upload") return save(intent.attachment)
    upload = intent
    writeConfig(b.sql, { [planKey]: JSON.stringify(upload) })
  }
  const url = new URL(upload.upload_url)
  if (url.origin !== new URL(origin).origin) throw new Error("chief.machine.reply_storage_pending")
  const token = url.pathname.split("/").at(-1)!
  try {
    if (upload.mode === "stream") {
      const result = await read<Receipt>(await handleAttachmentUpload(new Request(url, { method: "PUT", body: bytes }), b.doEnv, conversation, token))
      return save(result.attachment)
    }
    if (upload.mode !== "multipart" || !upload.slot || !upload.part_size || !upload.part_count) throw new Error("chief.machine.reply_storage_pending")
    for (let part = 1; part <= upload.part_count; part++) {
      await read(await handleAttachmentMultipartPart(new Request(url, { method: "PUT", headers: { "x-cmux-part-number": String(part) }, body: bytes.slice((part - 1) * upload.part_size, part * upload.part_size) }), b.doEnv, conversation, token))
    }
    const result = await read<Receipt>(await handleAttachmentMultipartComplete(request("/v1/home/attachments/multipart/complete", { conversation, slot: upload.slot }), b.doEnv, principal))
    return save(result.attachment)
  } catch (error) {
    // A lost stream commit is found by hash at the next intent. Multipart retries keep their
    // saved slot: recorded parts and an uncertain completion are idempotent on that slot.
    if (upload.mode === "stream" || (error as { code?: string } | null)?.code === "attachment.slot_invalid") b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, planKey)
    throw error
  }
}
