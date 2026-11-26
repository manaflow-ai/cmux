import { RELAY_FRAME_HEADER_LEN, RELAY_FRAME_MAX_PAYLOAD, RELAY_FRAME_VERSION, type TaggedRecord } from "./relay-frame.ts"

/** Interactive state: a tagged record of this class is superseded by a newer one with the same key (R5). */
export const CLASS_LATEST_WINS = 1
/** More queued than this and the queue is flushed at once (one full frame), so it never grows past a frame. */
export const COALESCE_FLUSH_BYTES = RELAY_FRAME_MAX_PAYLOAD

/** `a` is newer than `b` in 32-bit serial arithmetic (a key seq wraps). */
export const seqNewer = (a: number, b: number): boolean => {
  const d = (a - b) >>> 0
  return d !== 0 && d < 0x80000000
}

/**
 * The records waiting to be forwarded to one socket (RFD 0142 R5 as far as a Durable Object can do it; see
 * relay-pop-hop.md). Records keep their arrival order; a class-1 record with a tag replaces every queued class-1
 * record of the same key with a lower key seq (and is itself dropped when a newer one is already queued). Class 0,
 * 2, 3 and 4 records are never dropped and nothing is reordered: a replacement is appended where the newer record
 * arrived, so it never jumps a control record that arrived before it.
 */
export class TaggedQueue {
  private records: TaggedRecord[] = []
  private queuedBytes = 0

  get bytes(): number {
    return this.queuedBytes
  }

  get length(): number {
    return this.records.length
  }

  /** Queues `record`; returns how many records latest-wins dropped (the record itself counts as one when stale). */
  add(record: TaggedRecord): number {
    let dropped = 0
    if (record.class === CLASS_LATEST_WINS && record.tag) {
      const [key, seq] = record.tag
      for (const queued of this.records) {
        if (queued.class === CLASS_LATEST_WINS && queued.tag && queued.tag[0] === key && seqNewer(queued.tag[1], seq)) return 1
      }
      const kept = this.records.filter((queued) => {
        const older = queued.class === CLASS_LATEST_WINS && queued.tag !== undefined && queued.tag[0] === key && seqNewer(seq, queued.tag[1])
        if (older) {
          this.queuedBytes -= queued.raw.length
          dropped += 1
        }
        return !older
      })
      this.records = kept
    }
    this.records.push(record)
    this.queuedBytes += record.raw.length
    return dropped
  }

  /** Every queued record as relay frames of `peer` (16 bytes), in order, each payload at most 16 KiB. Empties it. */
  drain(peer: Uint8Array, kind: number): Uint8Array[] {
    const frames: Uint8Array[] = []
    let batch: TaggedRecord[] = []
    let size = 0
    const emit = () => {
      if (batch.length === 0) return
      const out = new Uint8Array(RELAY_FRAME_HEADER_LEN + size)
      out[0] = RELAY_FRAME_VERSION
      out[1] = kind
      out.set(peer, 2)
      let at = RELAY_FRAME_HEADER_LEN
      for (const r of batch) {
        out.set(r.raw, at)
        at += r.raw.length
      }
      frames.push(out)
      batch = []
      size = 0
    }
    for (const r of this.records) {
      if (size + r.raw.length > RELAY_FRAME_MAX_PAYLOAD) emit()
      batch.push(r)
      size += r.raw.length
    }
    emit()
    this.records = []
    this.queuedBytes = 0
    return frames
  }
}
