/**
 * Inbound texts from the provider webhook (section 19), parsed and checked
 * before anything is routed. Pure: the Worker passes the verified payload
 * (verifySendblueWebhook), our line numbers and the clock.
 */
export const INBOUND_MAX_AGE_MS = 10 * 60_000

/** `yes` means start only while the number is suppressed; otherwise it is an ordinary reply. */
export type Keyword = "stop" | "help" | "start" | "yes"
/** The one keyword table (also used by the delivery webhook). */
export const KEYWORDS: Readonly<Record<string, Keyword>> = {
  STOP: "stop", STOPALL: "stop", UNSUBSCRIBE: "stop", CANCEL: "stop", END: "stop", QUIT: "stop", "停止": "stop",
  HELP: "help", INFO: "help",
  START: "start", UNSTOP: "start",
  YES: "yes"
}
export const keywordOf = (content: string): Keyword | null => KEYWORDS[content.trim().toUpperCase()] ?? null

export interface Inbound {
  readonly handle: string
  readonly from: string
  readonly line: string
  readonly content: string
  readonly service: string
  readonly group_id: string | null
  readonly sent_at: number
  readonly keyword: Keyword | null
}

const E164 = /^\+[1-9][0-9]{7,14}$/

export const parseInbound = (payload: unknown, ourLines: ReadonlyArray<string>, now: number): { ok: true; inbound: Inbound } | { ok: false; code: string } => {
  const p = payload as Record<string, unknown> | null
  if (!p || p.is_outbound !== false) return { ok: false, code: "inbound.not_inbound" }
  const handle = p.message_handle
  const from = p.number
  // Inbound: the user's number is `number`, our line is `to_number`.
  const line = typeof p.to_number === "string" && ourLines.includes(p.to_number) ? p.to_number : undefined
  if (typeof handle !== "string" || handle.length === 0 || handle.length > 128) return { ok: false, code: "inbound.invalid" }
  if (typeof from !== "string" || !E164.test(from) || ourLines.includes(from)) return { ok: false, code: "inbound.invalid" }
  if (typeof line !== "string") return { ok: false, code: "inbound.not_our_line" }
  const content = typeof p.content === "string" ? p.content.slice(0, 18_996) : ""
  const keyword = keywordOf(content)
  const sent = typeof p.date_sent === "string" ? Date.parse(p.date_sent) : NaN
  // An opt-out always applies, however late it arrives; everything else must be fresh.
  const stale = !Number.isFinite(sent) || now - sent > INBOUND_MAX_AGE_MS || sent - now > 60_000
  if (stale && keyword !== "stop") return { ok: false, code: "inbound.stale" }
  return {
    ok: true,
    inbound: {
      handle,
      from,
      line,
      content,
      service: typeof p.service === "string" ? p.service : "SMS",
      group_id: typeof p.group_id === "string" && p.group_id.length > 0 ? p.group_id : null,
      sent_at: Number.isFinite(sent) ? sent : now,
      keyword
    }
  }
}
