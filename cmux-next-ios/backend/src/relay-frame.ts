/**
 * The relay frame of the link's WebSocket relay (PROTOCOL.md "WebSocket relay"), byte for byte the overlay relay
 * frame of `cmux_transport::relay_frame` in cmux-tui, which the phone and the Mac encode with. This copy checks
 * itself against the same golden vectors (cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json).
 *
 * `[u8 version = 1][u8 kind][16-byte peer id][payload <= 16 KiB]`, one frame per WebSocket binary message. A
 * `datagrams` payload is one or more `[u16 big-endian length > 0][datagram]` records that tile it exactly.
 * Decoders check in this order: short, version, kind, too_large, bad_batch. The relay reads only the header and
 * the batch framing: the datagrams are WireGuard ciphertext it cannot read. A `tagged-datagrams` frame (kind 4,
 * cmux-transport `RelayFrame::tagged_datagrams`, vectors in relay-tagged-frames.json) carries hop/1 DATA records.
 */
export const RELAY_FRAME_VERSION = 1
export const RELAY_FRAME_HEADER_LEN = 18
export const RELAY_FRAME_MAX_PAYLOAD = 16 * 1024
/** The largest frame a socket may send: a header and a full payload. */
export const RELAY_FRAME_MAX = RELAY_FRAME_HEADER_LEN + RELAY_FRAME_MAX_PAYLOAD

export type FrameKind = "datagrams" | "candidates" | "wake" | "tagged-datagrams"
const BYTE_KIND: ReadonlyArray<FrameKind | undefined> = [undefined, "datagrams", "candidates", "wake", "tagged-datagrams"]

export type FrameError = "short" | "version" | "kind" | "too_large" | "bad_batch"

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

/** One hop/1 DATA record of a `tagged-datagrams` payload (docs/cmux-next/relay-pop-hop.md). */
export interface TaggedRecord {
  readonly class: number
  /** `[key, keySeq]`, present when flags & 1. */
  readonly tag: readonly [number, number] | undefined
  /** The whole record bytes, header included, a view into the payload. */
  readonly raw: Uint8Array
}

/**
 * The records of a `tagged-datagrams` payload: `[u8 class][u8 flags][u32 key, u32 key_seq if flags & 1][u16 len > 0]
 * [bytes]`, tiling it exactly, at least one. Only flag bit 0 is defined; another bit is `bad_batch` (the record's
 * length could not be read past it). `undefined` when it does not tile.
 */
export const splitTagged = (payload: Uint8Array): TaggedRecord[] | undefined => {
  const records: TaggedRecord[] = []
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
  let offset = 0
  while (offset < payload.length) {
    if (payload.length - offset < 2) return undefined
    const start = offset
    const cls = payload[offset]!
    const flags = payload[offset + 1]!
    if (flags & ~1) return undefined
    offset += 2
    let tag: [number, number] | undefined
    if (flags & 1) {
      if (payload.length - offset < 8) return undefined
      tag = [view.getUint32(offset), view.getUint32(offset + 4)]
      offset += 8
    }
    if (payload.length - offset < 2) return undefined
    const len = view.getUint16(offset)
    offset += 2
    if (len === 0 || payload.length - offset < len) return undefined
    offset += len
    records.push({ class: cls, tag, raw: payload.subarray(start, offset) })
  }
  return records.length > 0 ? records : undefined
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
  if (kind === "tagged-datagrams" && !splitTagged(payload)) return { ok: false, error: "bad_batch" }
  return { ok: true, kind }
}

/** The same frame with `peer` set to `peer` (16 bytes): the relay never forwards a client's own value. */
export const withPeer = (bytes: Uint8Array, peer: Uint8Array): Uint8Array => {
  const out = new Uint8Array(bytes)
  out.set(peer, 2)
  return out
}
