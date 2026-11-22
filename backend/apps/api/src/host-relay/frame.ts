/**
 * The overlay relay frame (plans/cmux-next/transport.md section 6), byte for byte the same as
 * `cmux_transport::relay_frame` in cmux-tui. Both sides check themselves against
 * cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json.
 *
 * `[u8 version = 1][u8 kind][16-byte peer id][payload <= 16 KiB]`, one frame per WebSocket
 * binary message. A `datagrams` payload is one or more `[u16 big-endian length > 0][datagram]`
 * records that tile it exactly. Decoders check in this order: short, version, kind, too_large,
 * bad_batch. The relay reads only the header and the batch framing; datagrams are WireGuard
 * ciphertext it cannot read.
 */
export const RELAY_FRAME_VERSION = 1
export const RELAY_FRAME_HEADER_LEN = 18
export const RELAY_FRAME_MAX_PAYLOAD = 16 * 1024

export type FrameKind = "datagrams" | "candidates" | "wake"
const KIND_BYTE: Record<FrameKind, number> = { datagrams: 1, candidates: 2, wake: 3 }
const BYTE_KIND: ReadonlyArray<FrameKind | undefined> = [undefined, "datagrams", "candidates", "wake"]

export type FrameError = "short" | "version" | "kind" | "too_large" | "bad_batch"

export interface RelayFrame {
  readonly kind: FrameKind
  /** 16-byte install or host id. */
  readonly peer: Uint8Array
  readonly payload: Uint8Array
}

export type Decoded = { readonly ok: true; readonly frame: RelayFrame } | { readonly ok: false; readonly error: FrameError }

/** The records of a `datagrams` payload, or `bad_batch`. */
export const splitBatch = (payload: Uint8Array): ReadonlyArray<Uint8Array> | "bad_batch" => {
  const records: Array<Uint8Array> = []
  let offset = 0
  while (offset < payload.length) {
    if (payload.length - offset < 2) return "bad_batch"
    const len = (payload[offset]! << 8) | payload[offset + 1]!
    if (len === 0 || payload.length - offset - 2 < len) return "bad_batch"
    records.push(payload.subarray(offset + 2, offset + 2 + len))
    offset += 2 + len
  }
  return records.length === 0 ? "bad_batch" : records
}

export const decodeFrame = (bytes: Uint8Array): Decoded => {
  if (bytes.length < RELAY_FRAME_HEADER_LEN) return { ok: false, error: "short" }
  if (bytes[0] !== RELAY_FRAME_VERSION) return { ok: false, error: "version" }
  const kind = BYTE_KIND[bytes[1]!]
  if (!kind) return { ok: false, error: "kind" }
  const payload = bytes.subarray(RELAY_FRAME_HEADER_LEN)
  if (payload.length > RELAY_FRAME_MAX_PAYLOAD) return { ok: false, error: "too_large" }
  if (kind === "datagrams" && splitBatch(payload) === "bad_batch") return { ok: false, error: "bad_batch" }
  return { ok: true, frame: { kind, peer: bytes.subarray(2, RELAY_FRAME_HEADER_LEN), payload } }
}

export const encodeFrame = (frame: RelayFrame): Uint8Array | FrameError => {
  if (frame.peer.length !== 16) return "short"
  if (frame.payload.length > RELAY_FRAME_MAX_PAYLOAD) return "too_large"
  if (frame.kind === "datagrams" && splitBatch(frame.payload) === "bad_batch") return "bad_batch"
  const out = new Uint8Array(RELAY_FRAME_HEADER_LEN + frame.payload.length)
  out[0] = RELAY_FRAME_VERSION
  out[1] = KIND_BYTE[frame.kind]
  out.set(frame.peer, 2)
  out.set(frame.payload, RELAY_FRAME_HEADER_LEN)
  return out
}

/** The same frame with `peer` replaced (the relay never trusts a client's peer field). */
export const withPeer = (bytes: Uint8Array, peer: Uint8Array): Uint8Array => {
  const out = new Uint8Array(bytes)
  out.set(peer, 2)
  return out
}
