import type { Principal } from "@cmux/ownership"
import type { MobileSession } from "./mobile-session.ts"

export interface ControlAttachment {
  readonly ctl: true
  readonly role: "host" | "device"
  readonly principal: Principal
  readonly subscribed: false
  streams: Array<string>
  mobile?: MobileSession
  /** The team whose directory admitted the socket, and when TeamDO last confirmed it. */
  readonly team: string
  checkedAt: number
}

/** How long a socket's admission is trusted before a frame re-asks TeamDO. */
export const ACCESS_CHECK_MS = 60_000
export const HOST_CAPS = ["read", "signal", "presence", "resume"]
export const MAX_DEVICES = 32
