import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { Env } from "../env.ts"
import type { SendOutcome } from "../chief-brain/brain-io.ts"

/**
 * A plain text message as the Chief (the kernel's send/reply, the ledger's failure post), in the thread of
 * `reply_to` when given. Idempotent by `key`, which is also its client_msg_id (they must be equal).
 */
export const postMessage = async (env: Env, principal: Principal, m: { conversation: string; text: string; key: string; reply_to?: string }): Promise<SendOutcome> => {
  const conv = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(m.conversation)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<{ frames: ReadonlyArray<OwnerFrame> }> }
  const params = { conversation: m.conversation, client_msg_id: m.key, parts: [{ type: "text", text: m.text }], ...(m.reply_to ? { reply_to: { message_id: m.reply_to, part_index: 0 } } : {}) }
  const res = await conv.submit(m.conversation, principal, { t: "op", op: "message.send", params, idempotency_key: m.key, origin: "script" }).catch((e: unknown) => ({ frames: [{ t: "reject", code: "owner.unreachable", message: String(e) }] as unknown as ReadonlyArray<OwnerFrame> }))
  const f = res.frames.find((x) => x.t === "result" || x.t === "reject") as { t: string; code?: string; message?: string; value?: { message_id?: string; seq?: number } } | undefined
  if (!f) return { ok: false, code: "owner.unreachable", message: "no reply from the owner" }
  if (f.t === "reject") return { ok: false, code: f.code ?? "rejected", message: f.message ?? "" }
  return { ok: true, message: f.value?.message_id ?? null, ...(typeof f.value?.seq === "number" ? { seq: f.value.seq } : {}) }
}
