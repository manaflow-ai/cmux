/**
 * Wire shapes of the ownership protocol (spec/sync-and-transport.md section 3,
 * ownership.md section 3). Plain data: these cross the network as JSON.
 */

/** The authenticated principal of a connection. Never taken from a request body. */
export interface Principal {
  /** Connection identity used for the idempotency ledger and single-writer records. */
  readonly identity: string
  readonly user?: string
  readonly team?: string
  readonly install?: string
  readonly agent?: string
  readonly grant?: string
  /**
   * How the connection authenticated: a human session or an install token.
   * `system` is built only inside a Durable Object for its own internal ops
   * (alarms, Workflow reports); the Worker never builds one from a request.
   */
  readonly kind?: "session" | "install" | "agent" | "system"
  readonly stack_user_id?: string
  readonly email?: string | null
  readonly display_name?: string
  /** Op classes of the principal's grant, resolved by the grant's owner (UserDO) for other owners. */
  readonly grant_classes?: ReadonlyArray<string>
  /** Token expiry (ms); long-lived connections close at this time. */
  readonly expires_at?: number
}

export type Origin = "user" | "cli" | "mcp" | "script" | "remote"

/** Client to owner: one typed op with a client-chosen idempotency key. */
export interface OpFrame {
  readonly t: "op"
  readonly op: string
  readonly params: unknown
  readonly idempotency_key: string
  readonly origin?: Origin
  readonly expected_revision?: string
}

/** Owner to subscribers: one committed event. `tx` tags every event a request caused. */
export interface EventFrame {
  readonly t: "event"
  readonly stream: string
  readonly seq: number
  readonly tx: string
  readonly op: string
  readonly params: unknown
  readonly actor: Principal
  readonly origin: Origin
  readonly at: number
}

/** Owner to requester. `replayed` is true when the key was already decided. */
export interface ResultFrame {
  readonly t: "result"
  readonly tx: string
  readonly idempotency_key: string
  readonly value: unknown
  readonly revision: string
  readonly replayed: boolean
}

export interface RejectFrame {
  readonly t: "reject"
  readonly tx: string
  readonly idempotency_key: string
  readonly code: string
  readonly message: string
  readonly details?: unknown
  readonly retryable: boolean
  readonly replayed: boolean
}

/**
 * Always the last frame of a request (also for rejects, no-ops and replays):
 * the write barrier. `sequence` is the seq of the request's last event, 0 when
 * it caused none.
 */
export interface SettledFrame {
  readonly t: "request-settled"
  readonly tx: string
  readonly idempotency_key: string
  readonly stream: string
  readonly sequence: number
  readonly ok: boolean
}

export interface DecidedKey {
  readonly idempotency_key: string
  readonly ok: boolean
  readonly sequence: number
}

/** A snapshot carries the requester's decided keys at the snapshot sequence. */
export interface SnapshotFrame<S = unknown> {
  readonly t: "snapshot"
  readonly stream: string
  readonly seq: number
  readonly state: S
  readonly decided: ReadonlyArray<DecidedKey>
}

export type OwnerFrame = EventFrame | ResultFrame | RejectFrame | SettledFrame | SnapshotFrame

export interface Reject {
  readonly code: string
  readonly message: string
  readonly details?: unknown
  readonly retryable?: boolean
}

export interface OutboxItem {
  /** Projection kind, for example `install.upsert`. */
  readonly kind: string
  /** Entity key in PlanetScale, for example the install id. */
  readonly entity: string
  readonly payload: unknown
}

export interface ReduceContext {
  readonly principal: Principal
  /** The request's channel (view-state rules, and owners that accept some ops only from a person). */
  readonly origin?: Origin
  readonly now: number
  readonly tx: string
  /** Deterministic id from the transaction, so mirror replay reproduces it. */
  readonly newId: (prefix: string) => string
}

export type ReduceResult<S> =
  | {
      readonly ok: true
      readonly state: S
      readonly value: unknown
      /** False for a valid op that changes nothing: no event, sequence 0. */
      readonly changed?: boolean
      readonly outbox?: ReadonlyArray<OutboxItem>
    }
  | ({ readonly ok: false } & Reject)

/**
 * One owner entity type. `reduce` is pure: the owner, mirror replay and the
 * intent overlay all call it (OwnershipConvergence.tla `Apply`).
 */
export interface Domain<S, P = unknown> {
  readonly initial: () => S
  readonly reduce: (state: S, op: string, params: P, ctx: ReduceContext) => ReduceResult<S>
  /** Authorization by grant and op class. A failure is not recorded in the ledger. */
  readonly authorize?: (state: S, op: string, params: P, principal: Principal) => Reject | undefined
}
