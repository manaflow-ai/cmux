/**
 * The relay-held send queue (RFD 0142 R8; PROTOCOL.md "Relay-held sends"), off unless `LINK_RELAY_HOLD=on`.
 *
 * A send the phone makes while the Mac is not joined to the session's relay (asleep, offline, mid-redial) rides
 * the phone's relay socket as one text frame, `{"type":"hold","id","sealed"}`. `sealed` is the store-and-forward
 * item (`mailbox-send-v1`): signed by the phone's identity key and sealed to the Mac's box key, with the
 * idempotency id inside the signature. The relay acks it at once (`held`, one relay RTT), keeps it in this
 * object's storage, and hands it to the Mac when the Mac joins (`held_item`); the Mac's `held_ack` deletes it.
 *
 * What the relay sees: the id (random, the composer's client message id), the sender's device id, the sealed
 * length, and times. Never the text: it holds no key. Bounded per session ([`HOLD_MAX_ITEMS`],
 * [`HOLD_MAX_CHARS`]), and every item expires with the P8 mailbox's default hold ([`HOLD_TTL_MS`], 10 minutes).
 * Delivery is at least once; the Mac applies an id at most once (`cmux_mobile_link::relay_hold::HeldInbox`, and
 * hostd's spent file for mailbox kinds), so a lost ack or a redelivery never runs a send twice.
 */

export const HOLD_TTL_MS = 10 * 60 * 1000
export const HOLD_MAX_ITEMS = 64
/** Sealed characters held per session, across items (the P8 per-phone bound). */
export const HOLD_MAX_CHARS = 524_288
/** One item's sealed characters (a sealed send of a few KiB; a frame never carries more). */
export const HOLD_MAX_ITEM_CHARS = 16_384

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const B64URL = /^[A-Za-z0-9_-]+={0,2}$/

export type HoldFrame = { type: "hold"; id: string; sealed: string } | { type: "held_ack"; id: string }

/** The hold frame in `text`, or null when it is not one (other text is ignored, as before). */
export const parseHoldFrame = (text: string): HoldFrame | null | "bad" => {
  if (text.length > HOLD_MAX_ITEM_CHARS + 256) return "bad"
  let v: unknown
  try {
    v = JSON.parse(text)
  } catch {
    return null
  }
  if (!v || typeof v !== "object") return null
  const o = v as Record<string, unknown>
  if (o.type !== "hold" && o.type !== "held_ack") return null
  const id = typeof o.id === "string" ? o.id.toLowerCase() : ""
  if (!UUID.test(id)) return "bad"
  if (o.type === "held_ack") return { type: "held_ack", id }
  const sealed = o.sealed
  if (typeof sealed !== "string" || sealed.length === 0 || sealed.length > HOLD_MAX_ITEM_CHARS || !B64URL.test(sealed)) return "bad"
  return { type: "hold", id, sealed }
}

export interface HeldItem {
  readonly id: string
  readonly from: string
  readonly to: string
  readonly sealed: string
  readonly at: number
  readonly expiresAt: number
  readonly seq: number
}

export type HoldAnswer =
  | { readonly type: "held"; readonly id: string; readonly depth: number; readonly expiresAt: number; readonly delivered?: true }
  | { readonly type: "hold_refused"; readonly id: string; readonly code: "full" | "bad" | "off" }

const itemKey = (to: string, seq: number) => `hold:${to}:${String(seq).padStart(12, "0")}`
const idKey = (id: string) => `holdid:${id}`
const doneKey = (id: string) => `holddone:${id}`
const SEQ_KEY = "holdseq"

/** The queue over one LinkRelay's storage. Every call is one storage transaction's worth of reads and writes. */
export class HoldQueue {
  constructor(private readonly storage: DurableObjectStorage) {}

  /** Hold `sealed` from `from` for `to`; the same id again answers its first ack and stores nothing. */
  async hold(from: string, to: string, id: string, sealed: string, now: number): Promise<HoldAnswer> {
    await this.purge(now)
    const done = await this.storage.get<number>(doneKey(id))
    if (done !== undefined) return { type: "held", id, depth: (await this.items(to)).length, expiresAt: done, delivered: true }
    const existing = await this.storage.get<string>(idKey(id))
    const items = await this.items(to)
    if (existing !== undefined) {
      const item = await this.storage.get<HeldItem>(existing)
      if (item) return { type: "held", id, depth: items.length, expiresAt: item.expiresAt }
    }
    const all = await this.allItems()
    const chars = all.reduce((n, i) => n + i.sealed.length, 0)
    if (all.length >= HOLD_MAX_ITEMS || chars + sealed.length > HOLD_MAX_CHARS) return { type: "hold_refused", id, code: "full" }
    const seq = ((await this.storage.get<number>(SEQ_KEY)) ?? 0) + 1
    const item: HeldItem = { id, from, to, sealed, at: now, expiresAt: now + HOLD_TTL_MS, seq }
    const key = itemKey(to, seq)
    await this.storage.put({ [SEQ_KEY]: seq, [key]: item, [idKey(id)]: key })
    await this.arm(item.expiresAt)
    return { type: "held", id, depth: items.length + 1, expiresAt: item.expiresAt }
  }

  /** `to` settled `id`: delete it and keep a tombstone until it would have expired. Returns the sender, if held. */
  async ack(to: string, id: string, now: number): Promise<string | undefined> {
    const key = await this.storage.get<string>(idKey(id))
    if (key === undefined) return undefined
    const item = await this.storage.get<HeldItem>(key)
    if (!item || item.to !== to) return undefined
    await this.storage.delete([key, idKey(id)])
    await this.storage.put(doneKey(id), Math.max(item.expiresAt, now))
    return item.from
  }

  /** What waits for `to`, oldest first, unexpired. */
  async items(to: string, now = Date.now()): Promise<HeldItem[]> {
    const map = await this.storage.list<HeldItem>({ prefix: `hold:${to}:` })
    return [...map.values()].filter((i) => i.expiresAt > now)
  }

  private async allItems(): Promise<HeldItem[]> {
    const map = await this.storage.list<HeldItem>({ prefix: "hold:" })
    return [...map.values()]
  }

  /** Delete expired items and tombstones; returns the next expiry, if any. */
  async purge(now: number): Promise<number | undefined> {
    let next: number | undefined
    const dead: string[] = []
    for (const [key, item] of await this.storage.list<HeldItem>({ prefix: "hold:" })) {
      if (item.expiresAt <= now) dead.push(key, idKey(item.id))
      else next = Math.min(next ?? Infinity, item.expiresAt)
    }
    for (const [key, until] of await this.storage.list<number>({ prefix: "holddone:" })) {
      if (until <= now) dead.push(key)
      else next = Math.min(next ?? Infinity, until)
    }
    for (let i = 0; i < dead.length; i += 128) await this.storage.delete(dead.slice(i, i + 128))
    return next
  }

  private async arm(at: number) {
    const current = await this.storage.getAlarm()
    if (current === null || current > at) await this.storage.setAlarm(at)
  }

  /** The alarm: purge and re-arm for what is left. */
  async onAlarm(now: number) {
    const next = await this.purge(now)
    if (next !== undefined) await this.storage.setAlarm(next)
  }
}
