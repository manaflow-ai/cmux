/**
 * A read whose connection was lost under it, sent once more on a fresh connection. 2026-11-28 14:23Z
 * staging: cmux-vm's ownership read lost its Hyperdrive connection and the answer surfaced as a 502 to
 * the cloud probe (manaflow-ai/cmux#64946 fixes that Worker); this Worker's per-call readers had the
 * same shape: one lost connection answered search.unavailable. Writes are never resent (the lost one
 * may have committed); only callers whose `attempt` opens its own connection and only reads use this.
 */

/**
 * The connection died, not the statement: Workers' socket message, or a driver's closed-connection code. A timeout is
 * never one, even when its message names the connection (pg's connect timeout reads "Connection terminated due to
 * connection timeout"): a resend would double a wait that already spent its bound.
 */
export const connectionLost = (error: unknown): boolean => {
  if (typeof error !== "object" || error === null) return false
  const code = (error as { code?: unknown }).code
  if (code === "ETIMEDOUT" || code === "PROTOCOL_SEQUENCE_TIMEOUT") return false
  if (typeof code === "string" && ["PROTOCOL_CONNECTION_LOST", "ECONNRESET", "EPIPE", "CONNECTION_CLOSED", "CONNECTION_ENDED", "CONNECTION_DESTROYED"].includes(code)) return true
  const message = (error as { message?: unknown }).message
  if (typeof message !== "string") return false
  const text = message.toLowerCase()
  if (text.includes("timeout") || text.includes("timed out")) return false
  return text.includes("network connection lost") || text.includes("connection terminated") || text.includes("connection lost")
}

/** Runs `attempt`, and once more when its connection was lost; any other failure is thrown as is. */
export const readResendingOnLostConnection = async <T>(attempt: () => Promise<T>): Promise<T> => {
  try {
    return await attempt()
  } catch (error) {
    if (!connectionLost(error)) throw error
    return attempt()
  }
}
