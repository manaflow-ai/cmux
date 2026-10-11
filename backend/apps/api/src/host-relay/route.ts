import { decodeFrame, withPeer, type FrameError } from "./frame.ts"

/**
 * Routing for one host's relay object (plans/cmux-next/transport.md section 6 and 9.1), as a pure
 * function so the security rules are tested without sockets:
 * - a client frame goes only to the host, with `peer` rewritten to the client's authenticated
 *   install (a client can never speak as another client or address another client);
 * - a host frame goes only to the client it names, with `peer` rewritten to the host id;
 * - a client whose install is not in the host's compiled reachability is refused;
 * - nothing is forwarded while the destination is not connected; malformed frames are dropped.
 */
/**
 * A relay peer id is 16 bytes: the first 16 bytes of SHA-256 over the public install or host id
 * (`inst_…`, `host_…`), shown here as 32 lowercase hex characters. The object derives it from the
 * authenticated principal when a socket connects; frames never choose it.
 */
export type Endpoint = { readonly role: "host" } | { readonly role: "client"; readonly peer: string }

export interface RelayView {
  /** 16-byte id of the host this object serves. */
  readonly hostPeer: Uint8Array
  readonly hostConnected: boolean
  /** Peer ids (hex) with a connected client socket. */
  readonly connectedClients: ReadonlySet<string>
  /** Peer ids (hex) the team policy lets reach this host (compiled by `TeamDO`). */
  readonly reachable: ReadonlySet<string>
}

export type Route =
  | { readonly forward: true; readonly to: Endpoint; readonly bytes: Uint8Array; readonly kind: string }
  | { readonly forward: false; readonly reason: FrameError | "not_reachable" | "host_offline" | "client_offline" }

export const hexId = (id: Uint8Array): string => Array.from(id, (b) => b.toString(16).padStart(2, "0")).join("")
export const idFromHex = (hex: string): Uint8Array => Uint8Array.from(hex.match(/../g) ?? [], (h) => Number.parseInt(h, 16))

export const route = (view: RelayView, from: Endpoint, bytes: Uint8Array): Route => {
  const decoded = decodeFrame(bytes)
  if (!decoded.ok) return { forward: false, reason: decoded.error }
  if (from.role === "client") {
    if (!view.reachable.has(from.peer)) return { forward: false, reason: "not_reachable" }
    if (!view.hostConnected) return { forward: false, reason: "host_offline" }
    return { forward: true, to: { role: "host" }, bytes: withPeer(bytes, idFromHex(from.peer)), kind: decoded.frame.kind }
  }
  const target = hexId(decoded.frame.peer)
  if (!view.reachable.has(target)) return { forward: false, reason: "not_reachable" }
  if (!view.connectedClients.has(target)) return { forward: false, reason: "client_offline" }
  return { forward: true, to: { role: "client", peer: target }, bytes: withPeer(bytes, view.hostPeer), kind: decoded.frame.kind }
}

/** The relay peer id of a public install or host id. */
export const peerIdOf = async (publicId: string): Promise<string> =>
  hexId(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(publicId))).subarray(0, 16))
