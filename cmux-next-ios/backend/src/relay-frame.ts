/**
 * The relay frame of the link's WebSocket relay (PROTOCOL.md "WebSocket relay"), byte for byte the overlay relay
 * frame of `cmux_transport::relay_frame` in cmux-tui, which the phone and the Mac encode with. This copy checks
 * itself against the same golden vectors (cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json).
 *
 * `[u8 version = 1][u8 kind][16-byte peer id][payload <= 16 KiB]`, one frame per WebSocket binary message. A
 * `datagrams` payload is one or more `[u16 big-endian length > 0][datagram]` records that tile it exactly.
 * Decoders check in this order: short, version, kind, too_large, bad_batch (datagrams) or bad_hub (hub). The relay reads only the header and
 * the batch framing: the datagrams are WireGuard ciphertext it cannot read.
 */
export const RELAY_FRAME_VERSION = 1
export const RELAY_FRAME_HEADER_LEN = 18
export const RELAY_FRAME_MAX_PAYLOAD = 16 * 1024
/** The largest frame a socket may send: a header and a full payload. */
export const RELAY_FRAME_MAX = RELAY_FRAME_HEADER_LEN + RELAY_FRAME_MAX_PAYLOAD

export type FrameKind = "datagrams" | "candidates" | "wake" | "hub"
const BYTE_KIND: ReadonlyArray<FrameKind | undefined> = [undefined, "datagrams", "candidates", "wake", undefined, "hub"]

export type FrameError = "short" | "version" | "kind" | "too_large" | "bad_batch" | "bad_hub"

/**
 * The three-way hub (RFD 0142 R6, `cmux_transport::hub`): a `hub` payload starts with a clear 35-byte header,
 * `[u8 version = 1][16-byte session id][u64 BE epoch][u64 BE seq][u8 source: 1 mac, 2 vm][u8 to: 0 viewers,
 * 1 mac, 2 vm]`, then a body the source sealed end to end to the session's viewers (with this header as its
 * associated data). The relay reads the header and nothing else; it holds no key.
 */
export const HUB_HEADER_VERSION = 1
export const HUB_HEADER_LEN = 35
export type HubRole = "mac" | "vm"
export type HubTo = "viewers" | HubRole
export interface HubHeader {
  readonly session: Uint8Array
  readonly epoch: bigint
  readonly seq: bigint
  readonly source: HubRole
  readonly to: HubTo
}
const ROLE_OF: ReadonlyArray<HubRole | undefined> = [undefined, "mac", "vm"]

/** The clear hub header of a `hub` payload, or null when it is short, of another version, or names an unknown role or target (or a source sending to itself). */
export const hubHeader = (payload: Uint8Array): HubHeader | null => {
  if (payload.length < HUB_HEADER_LEN || payload[0] !== HUB_HEADER_VERSION) return null
  const source = ROLE_OF[payload[33]!]
  if (!source) return null
  const toByte = payload[34]!
  const to: HubTo | undefined = toByte === 0 ? "viewers" : ROLE_OF[toByte]
  if (!to || to === source) return null
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
  return { session: payload.subarray(1, 17), epoch: view.getBigUint64(17), seq: view.getBigUint64(25), source, to }
}

/** Whether a `datagrams` payload's records tile it exactly (none empty, at least one). */
export const batchTiles = (payload: Uint8Array): boolean => {
  let offset = 0
  let records = 0
  while (offset < payload.length) {
    if (payload.length - offset < 2) return false
    const len = (payload[offset]! << 8) | payload[offset + 1]!
    if (len === 0 || payload.length - offset - 2 < len) return false
    offset += 2 + len
    records += 1
  }
  return records > 0
}

/** The frame's kind, or why it is not one. */
export const checkFrame = (bytes: Uint8Array): { ok: true; kind: FrameKind } | { ok: false; error: FrameError } => {
  if (bytes.length < RELAY_FRAME_HEADER_LEN) return { ok: false, error: "short" }
  if (bytes[0] !== RELAY_FRAME_VERSION) return { ok: false, error: "version" }
  const kind = BYTE_KIND[bytes[1]!]
  if (!kind) return { ok: false, error: "kind" }
  const payload = bytes.subarray(RELAY_FRAME_HEADER_LEN)
  if (payload.length > RELAY_FRAME_MAX_PAYLOAD) return { ok: false, error: "too_large" }
  if (kind === "datagrams" && !batchTiles(payload)) return { ok: false, error: "bad_batch" }
  if (kind === "hub" && !hubHeader(payload)) return { ok: false, error: "bad_hub" }
  return { ok: true, kind }
}

/** The same frame with `peer` set to `peer` (16 bytes): the relay never forwards a client's own value. */
export const withPeer = (bytes: Uint8Array, peer: Uint8Array): Uint8Array => {
  const out = new Uint8Array(bytes)
  out.set(peer, 2)
  return out
}
