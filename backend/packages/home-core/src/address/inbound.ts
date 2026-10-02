/**
 * Inbound texts from the provider webhook (section 19), parsed and checked
 * before anything is routed. Pure: the Worker passes the verified payload
 * (verifySendblueWebhook), our line numbers and the clock.
 */
export const INBOUND_MAX_AGE_MS = 10 * 60_000

export type Keyword = "stop" | "help" | "start"
const KEYWORDS: Readonly<Record<string, Keyword>> = { STOP: "stop", STOPALL: "stop", UNSUBSCRIBE: "stop", CANCEL: "stop", END: "stop", QUIT: "stop", HELP: "help", INFO: "help", START: "start", UNSTOP: "start", YES: "start" }

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
  const line = [p.to_number, p.from_number].find((n) => typeof n === "string" && ourLines.includes(n))
  if (typeof handle !== "string" || handle.length === 0 || handle.length > 128) return { ok: false, code: "inbound.invalid" }
  if (typeof from !== "string" || !E164.test(from) || ourLines.includes(from)) return { ok: false, code: "inbound.invalid" }
  if (typeof line !== "string") return { ok: false, code: "inbound.not_our_line" }
  const sent = typeof p.date_sent === "string" ? Date.parse(p.date_sent) : NaN
  if (!Number.isFinite(sent) || now - sent > INBOUND_MAX_AGE_MS || sent - now > 60_000) return { ok: false, code: "inbound.stale" }
  const content = typeof p.content === "string" ? p.content.slice(0, 18_996) : ""
  const word = content.trim().toUpperCase()
  return {
    ok: true,
    inbound: {
      handle,
      from,
      line,
      content,
      service: typeof p.service === "string" ? p.service : "SMS",
      group_id: typeof p.group_id === "string" && p.group_id.length > 0 ? p.group_id : null,
      sent_at: sent,
      keyword: KEYWORDS[word] ?? null
    }
  }
}
