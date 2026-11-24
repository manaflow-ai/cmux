/**
 * Who may use the link's WebSocket relay, and how much (PROTOCOL.md "WebSocket relay"). Pure helpers the user
 * hub (TeamHub) and the relay object (LinkRelay) share.
 */

/**
 * A relay ticket: 32 random bytes, base64url. The hub makes one per device of each session when the session
 * opens, stamps it (`relayTicket`) on every `wg-*` signal it forwards to that device's own signaling socket, and
 * admits a relay join for that device only with it. The Stack token says which user is joining; the ticket says
 * which of the user's devices, as far as the hub can know: the device whose signaling socket received it.
 */
export const newTicket = (): string => {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

/** Constant-time equality of a presented ticket with the stored one (both short ASCII strings). */
export const ticketsMatch = (presented: string | null | undefined, stored: string | null | undefined): boolean => {
  if (!presented || !stored || presented.length !== stored.length) return false
  let diff = 0
  for (let i = 0; i < stored.length; i++) diff |= presented.charCodeAt(i) ^ stored.charCodeAt(i)
  return diff === 0
}

/** One mebibyte: the budget's unit, and the largest grant the relay asks the user's hub for at once. */
export const MIB = 1024 * 1024
/**
 * A socket's first grant, doubled with each further grant up to [`MIB`] while it keeps relaying: an idle link's
 * keepalives (about 100 bytes every 10 s) live off this for hours, so idle sockets hold almost none of the
 * user's budget, and a busy one asks the hub a few times a second at most.
 */
export const FIRST_GRANT = 64 * 1024

/**
 * What one user (in one build space) may relay per minute, in MiB, across all of its sessions, unless
 * `LINK_RELAY_USER_MIB_PER_MIN` says otherwise: 8 MiB/s sustained, the same as one socket's own limit, so two
 * relayed links share it and a user cannot fan out sessions into a bigger pipe.
 */
export const DEFAULT_USER_MIB_PER_MIN = 480

/** A token bucket of MiB, refilled per millisecond up to one minute's worth. Memory only: a wake forgets it. */
export class MibBucket {
  private tokens: number
  private at: number

  constructor(private readonly perMinute: number, now = Date.now()) {
    this.tokens = perMinute
    this.at = now
  }

  /** Take `mib` if there is that much left. */
  take(mib: number, now = Date.now()): boolean {
    this.tokens = Math.min(this.perMinute, this.tokens + ((now - this.at) / 60_000) * this.perMinute)
    this.at = now
    if (this.tokens < mib) return false
    this.tokens -= mib
    return true
  }
}

/** The per-minute budget the environment names, else the default. */
export const userMibPerMinute = (value: string | undefined): number => {
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_USER_MIB_PER_MIN
}

/** Close codes of relay sockets the service ends (PROTOCOL.md "WebSocket relay"). */
export const RELAY_CLOSE = {
  /** A newer socket of the same device replaced this one. */
  replaced: 4000,
  /** The session ended (`bye`). */
  ended: 4001,
  /** A device of the session, or the account, was removed. */
  removed: 4002,
  /** The relay is turned off (`LINK_RELAY_MODE=off`). */
  off: 4003,
} as const
