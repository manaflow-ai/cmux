/**
 * Auto mode's store (plans/cmux-next/auto-mode/DESIGN.md, "Model" and "Cloud API"): the record of one Auto chat
 * and the view every route answers. An Auto chat runs on the laptop while the laptop is there and on the owner's
 * Cloud machine when it is not; the store is where both learn who runs it now.
 *
 * Every chat has one holder: `device:<id>` (a laptop), `vm:<machine>` (a Cloud machine) or `parked` (nobody).
 * The epoch grows by one at every change of holder and never otherwise, and every write names the writer's holder
 * and epoch, so a laptop that slept through a takeover cannot write over the machine that took its chat.
 *
 * This file is types and constants only. The rules that move a record are in lease.ts (pure); the rows are in
 * record-store.ts, events.ts, snapshots.ts and inbox.ts; session-do.ts ties them to one Durable Object.
 */

/** How often a holder renews, how long a lease lasts from its last renewal, and when a laptop with no answer stops itself. */
export const RENEW_MS = 10_000
export const LEASE_MS = 45_000
export const SELF_STOP_MS = 35_000
/** The longest one wait holds a request (a chat's wait and a machine's assignments). */
export const MAX_WAIT_MS = 25_000
/** One chunk, and all the chunks one snapshot of a chat may name. */
export const MAX_CHUNK_BYTES = 1024 * 1024
export const MAX_CHAT_BYTES = 512 * 1024 * 1024
/** One events request: its count and its body. A chat's stored events share the chunk limit. */
export const MAX_EVENTS_PER_POST = 256
export const MAX_EVENTS_POST_BYTES = 1024 * 1024
export const MAX_MANIFEST_BYTES = 1024 * 1024
export const MAX_MANIFEST_CHUNKS = 4096
export const MAX_INBOX_TEXT_BYTES = 256 * 1024
/** Messages a chat holds for a holder that has not acked them. */
export const MAX_INBOX_PENDING = 256
/** Laptops remembered as waiting for one chat. */
export const MAX_STANDBY = 8

export const PARKED = "parked"
export const isVm = (holder: string): boolean => holder.startsWith("vm:")
export const isDevice = (holder: string): boolean => holder.startsWith("device:")
export const vmHolder = (machine: string): string => `vm:${machine}`

export type AssignmentKind = "takeover" | "create" | "deliver"
export type AutoState = "local" | "cloud" | "resuming" | "parked" | "coming_back"
export type InboxState = "delivered" | "resuming" | "queued"
export type AutoRepo = { readonly remote: string; readonly branch: string }
/** The owner's Auto machine: the Cloud machine their Auto chats move to. */
export type AutoMachine = { readonly team: string; readonly machine: string }
/** A laptop that is online, has the chat, and does not hold it. It stops counting when it stops renewing. */
export type Standby = { readonly holder: string; readonly expiresAt: number }

/** One chat's record: the row of record-store.ts. */
export type AutoRecord = {
  readonly id: string
  readonly owner: string
  /** The team the chat runs in: its creator's, then its machine's. */
  readonly team: string | null
  readonly title: string
  readonly harness: string
  /** False once the owner turned Auto off for the chat (closed): its Cloud copy is gone and writes are refused. */
  readonly auto: boolean
  readonly keepInCloud: boolean
  readonly holder: string
  readonly epoch: number
  /** What the holder said at its last renewal: a turn running, a prompt queued or a background task at work. */
  readonly needsRun: boolean
  readonly standby: ReadonlyArray<Standby>
  readonly blocked: "no_machine" | null
  /** What the holding machine still has to pick up; null once it acked. */
  readonly assignment: AssignmentKind | null
  /** The Cloud machine that holds the chat or held it last. */
  readonly machine: string | null
  /** The laptop whose lease ran straight into `parked`: nobody ran the chat since, so it may take it back as it is. */
  readonly parkedFrom: string | null
  /** The epoch a laptop named when it took its own parked chat back (0: none), so a repeat of that renewal after a lost answer is the same renewal. */
  readonly resumedEpoch: number
  /**
   * The holder is a laptop that was given the chat (a hand-back, or a parked chat another holder ran last) and has
   * stored no snapshot of its own since: what the last holder did may be in the Cloud copy alone. Auto off is
   * refused until it has, and its lease running out parks the chat as the Cloud's, not as that laptop's.
   */
  readonly owesImport: boolean
  readonly lastSeq: number
  /** The newest snapshot's number, and the `lastSeq` its manifest names. */
  readonly snapshot: number
  readonly snapshotSeq: number
  readonly inbox: number
  readonly inboxAcked: number
  readonly repo: AutoRepo | null
  /** The size of the chat's stored events (the chunks count themselves: snapshots.ts). */
  readonly eventBytes: number
  /** Counts every change a viewer can see; a wait passes the last one it saw. */
  readonly version: number
  readonly createdAt: number
  readonly updatedAt: number
  readonly leaseExpiresAt: number
}

/** The view every route answers (DESIGN.md "Cloud API"). Times are milliseconds since the epoch. */
export type AutoSessionView = {
  readonly id: string
  readonly title: string
  readonly harness: string
  readonly team: string | null
  readonly owner: string
  readonly auto: boolean
  readonly keepInCloud: boolean
  readonly holder: string
  readonly epoch: number
  readonly state: AutoState
  readonly blocked: "no_machine" | null
  readonly needsRun: boolean
  readonly standby: ReadonlyArray<string>
  readonly lastSeq: number
  readonly snapshot: number
  readonly inbox: number
  readonly inboxAcked: number
  readonly repo: AutoRepo | null
  readonly version: number
  readonly createdAt: number
  readonly updatedAt: number
  readonly leaseExpiresAt: number
}

/** Who is asking: the owner (a signed-in session or a person's install) or the VM install bound to one of the owner's machines. */
/**
 * `install` (an owner's caller from a route): the id of the install that called when it is one that holds chats (a
 * laptop's cmux), null for one that never does (a phone, a browser session). Unset on the store's own reads.
 */
export type AutoCaller = { readonly kind: "owner"; readonly owner: string; readonly install?: string | null } | { readonly kind: "machine"; readonly owner: string; readonly machine: string }

export type AutoFail =
  | "not_found"
  | "auto.stale_epoch"
  | "auto.not_holder"
  | "auto.no_machine"
  | "auto.held_in_cloud"
  | "auto.seq_gap"
  | "auto.snapshot_incomplete"
  | "auto.no_snapshot"
  | "auto.chunk_mismatch"
  | "auto.too_large"
  | "auto.closed"
  | "auto.wrong_device"
  | "auto.not_a_laptop"
/** A refusal carries the chat as it is now (when the caller may see it), and what the code promises: `lastSeq`, `missing`. */
export type RefusalExtra = { readonly lastSeq?: number; readonly missing?: ReadonlyArray<string> }
export type AutoRefusal = { readonly ok: false; readonly code: AutoFail; readonly message: string; readonly session?: AutoSessionView; readonly extra?: RefusalExtra }
export type AutoResult<T> = { readonly ok: true; readonly value: T } | AutoRefusal

/** The owner's index row for one chat (index-do.ts): its view, and the assignment its machine has not acked. */
export type AutoIndexEntry = {
  readonly id: string
  readonly owner: string
  readonly view: AutoSessionView
  readonly assignment: { readonly kind: AssignmentKind; readonly machine: string; readonly team: string } | null
}

export const liveStandby = (r: Pick<AutoRecord, "standby">, now: number): ReadonlyArray<Standby> => r.standby.filter((s) => s.expiresAt > now)
export const pendingInbox = (r: Pick<AutoRecord, "inbox" | "inboxAcked">): boolean => r.inbox > r.inboxAcked

/** What a client shows: `resuming` until the machine acked what it was given, `coming_back` when the chat goes home at the next turn end. */
export const stateOf = (r: AutoRecord, now: number): AutoState => {
  if (r.holder === PARKED) return "parked"
  if (!isVm(r.holder)) return "local"
  if (r.assignment !== null) return "resuming"
  return !r.keepInCloud && liveStandby(r, now).length > 0 ? "coming_back" : "cloud"
}

export const viewOf = (r: AutoRecord, now: number): AutoSessionView => ({
  id: r.id,
  title: r.title,
  harness: r.harness,
  team: r.team,
  owner: r.owner,
  auto: r.auto,
  keepInCloud: r.keepInCloud,
  holder: r.holder,
  epoch: r.epoch,
  state: stateOf(r, now),
  blocked: r.blocked,
  needsRun: r.needsRun,
  standby: liveStandby(r, now).map((s) => s.holder),
  lastSeq: r.lastSeq,
  snapshot: r.snapshot,
  inbox: r.inbox,
  inboxAcked: r.inboxAcked,
  repo: r.repo,
  version: r.version,
  createdAt: r.createdAt,
  updatedAt: r.updatedAt,
  leaseExpiresAt: r.leaseExpiresAt
})
