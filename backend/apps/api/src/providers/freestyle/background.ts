/**
 * Freestyle background requests, for an `exec-await` this Worker sends straight to the provider (with the API key
 * or a Chief identity token).
 *
 * Freestyle's edge cuts a request it holds open at about 120 s: an exec-await of a command with a 290 s timeout
 * answered 524 after 125 s (production, 2026-11-21), though exec-await runs a command for up to 300 s. With
 * BACKGROUND_AFTER, a request still running after 60 s answers 202 with a request id instead; the provider
 * finishes it on its own, and GET /v5/background-requests/{id} answers 202 until the stored answer is ready, then
 * that answer. cmux-vm (workers/cmux-vm/src/upstream/live-background.ts), the cmux CLI (cmux-cloud-api
 * background.rs) and Freestyle's own SDK (freestyle 0.2.21 client.ts) do the same; an identity token polls its own
 * exec's answer (the poll route rechecks its VM and Linux-user grant).
 *
 * The provider stores a background request's answer, so a call that carries a key (the stdin of a keyed start or
 * a boot) never sends the header: its caller keeps the guest timeout short, and a 202 still fails it.
 */

export const BACKGROUND_AFTER_HEADER = "x-freestyle-background-after-secs"
/** Well before the edge's cut; a short exec (a 30 s step) stays one request, with no poll added. */
export const BACKGROUND_AFTER_SECS = 60
/** The header that lets a long request answer 202 instead of being held open. */
export const BACKGROUND_AFTER: Readonly<Record<string, string>> = { [BACKGROUND_AFTER_HEADER]: String(BACKGROUND_AFTER_SECS) }
const ID_HEADER = "x-freestyle-background-request-id"
const REQUEST_ID = /^[A-Za-z0-9_.:-]{1,128}$/
const POLL_TIMEOUT_MS = 30_000
/** The longest wait between polls while the provider fails them (the wait doubles from the poll interval). */
const MAX_BACKOFF_MS = 15_000
/**
 * How often a stored answer is polled (the SDK's 2 s), and how long polls may fail (no answer, 429 or 5xx) since
 * the last answered one before the answer is given up as lost. The outage window is apart from the caller's
 * deadline, the way a CDN keeps its origin timeout apart from its retry window: the provider stores the answer,
 * so an overload (Freestyle answered 503 to every poll for 9 min, rebake 45960390204, 2026-11-27) is waited out
 * instead of losing a command that ran. Tests set both lower.
 */
export const backgroundPoll = { ms: 2_000, outageMs: 300_000 }
const ACCEPTED_MAX_BYTES = 4096
/**
 * A 202 whose stored answer did not come: by the deadline, or (`outage`) while the provider failed every poll for
 * the outage window. The command may have run.
 */
export class BackgroundLost extends Error {
  constructor(readonly outage = false) {
    super(
      outage
        ? `background request: provider outage, no poll answered for ${Math.round(backgroundPoll.outageMs / 1000)} s (the command may have run)`
        : "background request: no answer by the deadline (the command may have run)"
    )
    this.name = "BackgroundLost"
  }
}

const requestId = async (accepted: Response): Promise<string | null> => {
  const header = accepted.headers.get(ID_HEADER)
  const text = await accepted.text().catch(() => "")
  let id: unknown = header
  if (id === null && text.length <= ACCEPTED_MAX_BYTES) {
    try {
      const body = JSON.parse(text) as { requestId?: unknown; request_id?: unknown } | null
      id = body?.requestId ?? body?.request_id
    } catch {
      id = null
    }
  }
  return typeof id === "string" && REQUEST_ID.test(id) ? id : null
}

/**
 * The final answer of `res`: itself unless it is a 202, else the stored answer of its background request, polled
 * at `base` with `headers` (the same credential, no body) until `deadlineAt` (epoch ms). Failed polls back off and
 * keep going, past the deadline too, until none has answered for `backgroundPoll.outageMs`. A stored refusal comes
 * back as that answer, whatever its status; BackgroundLost when no answer came. `polled` says the answer is a
 * stored one: the command ran, so a caller never sends it again on that answer.
 */
export const settleBackground = async (
  res: Response,
  base: string,
  headers: Readonly<Record<string, string>>,
  deadlineAt: number,
  fetchFn: typeof fetch = fetch
): Promise<{ res: Response; polled: boolean }> => {
  if (res.status !== 202) return { res, polled: false }
  const id = await requestId(res)
  if (id === null) throw new BackgroundLost()
  const url = `${base.replace(/\/+$/, "")}/v5/background-requests/${id}`
  let lastAnswerAt = Date.now()
  let wait = backgroundPoll.ms
  let failing = false
  for (;;) {
    const outageEndsAt = lastAnswerAt + backgroundPoll.outageMs
    if (failing ? Date.now() + wait >= Math.max(deadlineAt, outageEndsAt) : Date.now() + wait >= deadlineAt) break
    await new Promise((r) => setTimeout(r, wait))
    const ms = Math.max(1, Math.min(POLL_TIMEOUT_MS, (failing ? Math.max(deadlineAt, outageEndsAt) : deadlineAt) - Date.now()))
    const poll = await fetchFn(url, { method: "GET", headers, redirect: "manual", signal: AbortSignal.timeout(ms) }).catch(() => null)
    // A stored answer carries the request id, whatever its status; a 429 or 5xx without it is the poll's own failure.
    if (poll && poll.status !== 202 && (poll.headers.has(ID_HEADER) || (poll.status !== 429 && poll.status < 500))) return { res: poll, polled: true }
    await poll?.body?.cancel().catch(() => undefined)
    if (poll?.status === 202) {
      lastAnswerAt = Date.now()
      wait = backgroundPoll.ms
      failing = false
    } else {
      failing = true
      wait = Math.min(MAX_BACKOFF_MS, wait * 2)
    }
  }
  throw new BackgroundLost(failing)
}
