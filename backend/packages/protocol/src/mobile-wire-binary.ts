import { MobileWireError } from "./mobile-wire.ts"

/**
 * cmux.mobile/1 stream-plane records (a0-rpc.md section 3). Header: u32 channel, u64 seq, u8 flags,
 * little-endian (the cmux.wire/1 channel header that terminal-snapshot-v1 frames sit behind), then
 * the payload. Message carriers send one record per message; byte-stream carriers prefix each
 * record with its u32 LE length. No JSON on the hot path: only `json`-flagged records parse JSON.
 */

export const RECORD_HEADER_LEN = 13
export const RECORD_LENGTH_PREFIX = 4
export const MAX_RECORD = 1 << 20

export const RecordFlag = { keyframe: 0x01, json: 0x02, credit: 0x04, fin: 0x08 } as const
export type RecordFlagName = keyof typeof RecordFlag
const KNOWN_FLAGS = 0x0f

/** Record decode errors, named as in schemas/mobile-rpc/fixtures/binary.json. */
export type RecordErrorCode = "truncated" | "reserved_flags" | "bad_credit" | "bad_json" | "bad_seq" | "too_large" | "bad_length"

export class RecordError extends MobileWireError {
  constructor(readonly reason: RecordErrorCode, message: string) {
    super("proto.bad_record", message)
  }
}

export interface StreamRecord {
  readonly channel: number
  /** Per channel and direction, from 1; 0 only on credit records. */
  readonly seq: bigint
  readonly flags: number
  readonly payload: Uint8Array
}

export interface CreditGrant {
  /** Highest contiguous seq the receiver applied. */
  readonly ackSeq: bigint
  /** Additional payload bytes the sender may have unacknowledged. */
  readonly grantBytes: number
}

const view = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength)

export const hasFlag = (record: Pick<StreamRecord, "flags">, flag: RecordFlagName): boolean => (record.flags & RecordFlag[flag]) !== 0

export const flagsOf = (names: ReadonlyArray<RecordFlagName>): number => names.reduce((acc, n) => acc | RecordFlag[n], 0)

export const flagNames = (flags: number): Array<RecordFlagName> => (Object.keys(RecordFlag) as Array<RecordFlagName>).filter((n) => (flags & RecordFlag[n]) !== 0)

/** Decodes one record (no length prefix) and checks the header rules of section 3.1. */
export const decodeRecord = (bytes: Uint8Array): StreamRecord => {
  if (bytes.byteLength < RECORD_HEADER_LEN) throw new RecordError("truncated", "record shorter than its header")
  if (bytes.byteLength > MAX_RECORD) throw new RecordError("too_large", "record above max_record")
  const v = view(bytes)
  const record: StreamRecord = { channel: v.getUint32(0, true), seq: v.getBigUint64(4, true), flags: v.getUint8(12), payload: bytes.subarray(RECORD_HEADER_LEN) }
  if ((record.flags & ~KNOWN_FLAGS) !== 0) throw new RecordError("reserved_flags", `reserved flag bits ${record.flags.toString(16)}`)
  if (hasFlag(record, "credit")) {
    if (record.flags !== RecordFlag.credit || record.seq !== 0n || record.payload.byteLength !== 12) throw new RecordError("bad_credit", "credit records carry seq 0, no other flag and 12 bytes")
  } else {
    if (record.seq === 0n) throw new RecordError("bad_seq", "data records start at seq 1")
    if (hasFlag(record, "json")) recordJson(record)
  }
  return record
}

export const encodeRecord = (record: StreamRecord): Uint8Array => {
  const out = new Uint8Array(RECORD_HEADER_LEN + record.payload.byteLength)
  const v = view(out)
  v.setUint32(0, record.channel, true)
  v.setBigUint64(4, record.seq, true)
  v.setUint8(12, record.flags)
  out.set(record.payload, RECORD_HEADER_LEN)
  if (out.byteLength > MAX_RECORD) throw new RecordError("too_large", "record above max_record")
  return out
}

export const creditRecord = (channel: number, grant: CreditGrant): StreamRecord => {
  const payload = new Uint8Array(12)
  const v = view(payload)
  v.setBigUint64(0, grant.ackSeq, true)
  v.setUint32(8, grant.grantBytes, true)
  return { channel, seq: 0n, flags: RecordFlag.credit, payload }
}

export const recordCredit = (record: StreamRecord): CreditGrant => {
  if (!hasFlag(record, "credit") || record.payload.byteLength !== 12) throw new RecordError("bad_credit", "not a credit record")
  const v = view(record.payload)
  return { ackSeq: v.getBigUint64(0, true), grantBytes: v.getUint32(8, true) }
}

/** Canonical JSON: sorted keys, no whitespace. Both codecs encode JSON records this way. */
export const canonicalRecordJson = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonicalRecordJson).join(",")}]`
  if (value !== null && typeof value === "object") {
    const o = value as Record<string, unknown>
    return `{${Object.keys(o).filter((k) => o[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonicalRecordJson(o[k])}`).join(",")}}`
  }
  return JSON.stringify(value)
}

export const jsonRecord = (channel: number, seq: bigint, json: Record<string, unknown>, extraFlags: ReadonlyArray<RecordFlagName> = []): StreamRecord => ({
  channel,
  seq,
  flags: RecordFlag.json | flagsOf(extraFlags),
  payload: new TextEncoder().encode(canonicalRecordJson(json))
})

export const recordJson = (record: StreamRecord): Record<string, unknown> => {
  let parsed: unknown
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(record.payload))
  } catch {
    throw new RecordError("bad_json", "json record payload is not UTF-8 JSON")
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new RecordError("bad_json", "json record payload is not an object")
  return parsed as Record<string, unknown>
}

/** Prefixes a record with its u32 LE length (byte-stream carriers). */
export const frameRecord = (record: StreamRecord): Uint8Array => {
  const body = encodeRecord(record)
  const out = new Uint8Array(RECORD_LENGTH_PREFIX + body.byteLength)
  view(out).setUint32(0, body.byteLength, true)
  out.set(body, RECORD_LENGTH_PREFIX)
  return out
}

/**
 * Splits a byte stream into records. Holds at most one partial record; consumed bytes are dropped
 * once per `push`, so many small records in one chunk cost linear time. After an error every call
 * throws it again (the carrier closes the session).
 */
export class RecordDeframer {
  private buf = new Uint8Array(0)
  private failure: RecordError | undefined

  push(chunk: Uint8Array): Array<StreamRecord> {
    if (this.failure) throw this.failure
    const joined = new Uint8Array(this.buf.byteLength + chunk.byteLength)
    joined.set(this.buf)
    joined.set(chunk, this.buf.byteLength)
    const out: Array<StreamRecord> = []
    let at = 0
    try {
      while (joined.byteLength - at >= RECORD_LENGTH_PREFIX) {
        const len = view(joined).getUint32(at, true)
        if (len > MAX_RECORD) throw new RecordError("too_large", `record length ${len} above max_record`)
        if (len < RECORD_HEADER_LEN) throw new RecordError("bad_length", `record length ${len} below the header`)
        if (joined.byteLength - at - RECORD_LENGTH_PREFIX < len) break
        out.push(decodeRecord(joined.slice(at + RECORD_LENGTH_PREFIX, at + RECORD_LENGTH_PREFIX + len)))
        at += RECORD_LENGTH_PREFIX + len
      }
    } catch (e) {
      this.failure = e instanceof RecordError ? e : new RecordError("bad_length", String(e))
      this.buf = new Uint8Array(0)
      throw this.failure
    }
    this.buf = joined.slice(at)
    return out
  }
}

/** Terminal channel, viewer to host: u8 kind + payload. */
export type TerminalInputKind = "bytes" | "paste"
export interface TerminalInput {
  readonly kind: TerminalInputKind
  readonly data: Uint8Array
}
const INPUT_KINDS: ReadonlyArray<TerminalInputKind> = ["bytes", "paste"]

export const encodeTerminalInput = (input: TerminalInput): Uint8Array => concat([INPUT_KINDS.indexOf(input.kind)], input.data)

export const decodeTerminalInput = (payload: Uint8Array): TerminalInput => {
  const kind = INPUT_KINDS[payload[0] ?? 255]
  if (payload.byteLength < 1 || kind === undefined) throw new RecordError("truncated", "unknown terminal input kind")
  return { kind, data: payload.subarray(1) }
}

/** Terminal channel, host to viewer: the terminal-snapshot-v1 sub-header (CmuxTerminalStream `TerminalFrame`). */
export type TerminalOutputKind = "bytes" | "snapshot_ready" | "snapshot_history" | "digest"
export interface TerminalOutput {
  readonly kind: TerminalOutputKind
  readonly generation: number
  readonly offset: bigint
  readonly snapshotVersion?: number
  readonly data: Uint8Array
}
const OUTPUT_KINDS: ReadonlyArray<TerminalOutputKind> = ["bytes", "snapshot_ready", "snapshot_history", "digest"]

export const encodeTerminalOutput = (o: TerminalOutput): Uint8Array => {
  const head = new Uint8Array(o.kind === "bytes" ? 13 : 15)
  const v = view(head)
  v.setUint8(0, OUTPUT_KINDS.indexOf(o.kind))
  v.setUint32(1, o.generation, true)
  v.setBigUint64(5, o.offset, true)
  if (o.kind !== "bytes") v.setUint16(13, o.snapshotVersion ?? 0, true)
  return concat(head, o.data)
}

export const decodeTerminalOutput = (payload: Uint8Array): TerminalOutput => {
  if (payload.byteLength < 13) throw new RecordError("truncated", "terminal frame shorter than its sub-header")
  const v = view(payload)
  const kind = OUTPUT_KINDS[v.getUint8(0)]
  if (kind === undefined) throw new RecordError("truncated", "unknown terminal frame kind")
  const base = { kind, generation: v.getUint32(1, true), offset: v.getBigUint64(5, true) }
  if (kind === "bytes") return { ...base, data: payload.subarray(13) }
  if (payload.byteLength < 15) throw new RecordError("truncated", "terminal snapshot frame without its version")
  return { ...base, snapshotVersion: v.getUint16(13, true), data: payload.subarray(15) }
}

/** files.* channels: u64 offset + bytes. */
export interface FileChunk {
  readonly offset: bigint
  readonly data: Uint8Array
}

export const encodeFileChunk = (c: FileChunk): Uint8Array => {
  const head = new Uint8Array(8)
  view(head).setBigUint64(0, c.offset, true)
  return concat(head, c.data)
}

export const decodeFileChunk = (payload: Uint8Array): FileChunk => {
  if (payload.byteLength < 8) throw new RecordError("truncated", "file chunk without its offset")
  return { offset: view(payload).getBigUint64(0, true), data: payload.subarray(8) }
}

/** browser and rd channels: one cmux.rd/1 stream frame without its u32 length (1 control, 2 datagram, 3 bulk). */
export interface RdStreamFrame {
  readonly type: 1 | 2 | 3
  readonly data: Uint8Array
}

export const encodeRdStreamFrame = (f: RdStreamFrame): Uint8Array => concat([f.type], f.data)

export const decodeRdStreamFrame = (payload: Uint8Array): RdStreamFrame => {
  const type = payload[0]
  if (type !== 1 && type !== 2 && type !== 3) throw new RecordError("truncated", "unknown rd stream frame type")
  return { type, data: payload.subarray(1) }
}

const concat = (head: ArrayLike<number>, tail: Uint8Array): Uint8Array => {
  const out = new Uint8Array(head.length + tail.byteLength)
  out.set(head)
  out.set(tail, head.length)
  return out
}
