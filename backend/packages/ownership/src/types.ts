import type { RowReader, RowWrite, StoredRow } from "./rows.ts"
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
  /** Automation principals only (built by the API Worker): the run that is calling. */
  readonly run?: string
  readonly grant?: string
  /**
   * How the connection authenticated: a human session or an install token.
   * `system` is built only inside a Durable Object for its own internal ops
   * (alarms, Workflow reports); the Worker never builds one from a request.
   */
  readonly kind?: "session" | "install" | "agent" | "system"
  readonly stack_user_id?: string
  readonly email?: string | null
  /**
   * True only when the identity provider asserted the email as verified (Stack claim
   * `email_verified === true`). Owners must check it before trusting `email` for binding or
   * access decisions (invite binding, unsuppress, email-domain rules).
   */
  readonly email_verified?: boolean
  readonly display_name?: string
  /** The install's registered kind (mac, ios, web, cli, daemon, vm), resolved by UserDO with the grant. */
  readonly install_kind?: string
  /** A VM install's one machine (kind vm, made at bind), resolved by UserDO with the grant. */
  readonly bound_machine?: string
  /**
   * Agents (chiefs) the user owns, resolved by the Worker from UserDO's chief records for ops
   * that add participants (Home). Owners trust it only because the Worker builds every
   * principal; frames and params never carry it.
   */
  /**
   * Team whose SSO issued this session or registered this install, for sso.enforce (P17-4). Set
   * only by the server: from TeamDO's record of the sessions its OIDC callback created (keyed by
   * the Stack-signed refresh_token_id), or from the install record. Never from a token claim.
   */
  readonly sso_team?: string
  /** The Stack session's refresh token id (Stack-signed claim `refresh_token_id`). */
  readonly stack_session?: string
  /**
   * Install tokens only: the user's email domain when the token was minted (our own signed claim,
   * from UserDO's record of the user's email), so sso.enforce can find the team that owns the domain.
   */
  readonly email_domain?: string
  readonly owned_agents?: ReadonlyArray<{ readonly id: string; readonly display_name: string }>
  /**
   * Home reach facts (home-messaging.md section 16), one per human the op would add, resolved by
   * the Worker from their owners (TeamDO membership, the caller's inbox and DMs, the target's
   * UserDO settings). Same trust as `owned_agents`: built only by the Worker, never from frames
   * or params; no entry means no link. A chief's facts are its owner's (owner's teams, owner's
   * connections, the target's setting checked against the owner). Shape: home-core `HumanReach`.
   */
  readonly home_reach?: ReadonlyArray<{
    readonly user: string
    readonly display_name: string
    readonly shared_team: boolean
    readonly connected: boolean
    readonly allow_requests_from: "anyone" | "teams" | "nobody"
    readonly blocked?: boolean
  }>
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
  /**
   * Row-mode owners (row-backed domains) send the op's effects: the new head state and
   * the row writes. A mirror applies them instead of replaying the reducer, so it needs
   * no rows it was never sent (the delta form of OwnershipConvergence.tla Apply).
   */
  readonly effects?: { readonly state: unknown; readonly writes: ReadonlyArray<RowWrite> }
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
  /** Row-mode owners: the newest rows of the snapshot table (for example the message tail). */
  readonly rows?: { readonly table: string; readonly rows: ReadonlyArray<StoredRow> }
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
  /**
   * DO-to-DO item (E4): drained by RPC to this object, at least once, as the op `kind` with
   * params `payload` and idempotency key `entity`. Absent = a PlanetScale projection row.
   */
  readonly target?: {
    readonly class: string
    readonly name: string
    /**
     * Items with the same coalesce key and target collapse to the newest in one drain (for
     * example one inbox bump per conversation). Only for max-merge ops whose newest item
     * subsumes the older ones; the kept item may be delivered after other items of the batch.
     */
    readonly coalesce?: string
  }
}

export interface ReduceContext {
  readonly principal: Principal
  /** The request's channel (view-state rules, and owners that accept some ops only from a person). */
  readonly origin?: Origin
  readonly now: number
  readonly tx: string
  /** Deterministic id from the transaction, so mirror replay reproduces it. */
  readonly newId: (prefix: string) => string
  /**
   * Read-only rows of a row-backed domain. The engine and mirrors always pass it (empty for
   * JSON-only domains); hand-built test contexts for JSON domains may omit it.
   */
  readonly rows?: RowReader
  /**
   * The request's idempotency key: present on the owner and in a client's preview of its own
   * intent; absent when a mirror replays a committed event (events hide keys behind `tx`).
   * A reducer may require it (for example message.send needs client_msg_id === key) only
   * when it is present.
   */
  readonly idempotencyKey?: string
}

export type ReduceResult<S> =
  | {
      readonly ok: true
      readonly state: S
      readonly value: unknown
      /** False for a valid op that changes nothing: no event, sequence 0. */
      readonly changed?: boolean
      readonly outbox?: ReadonlyArray<OutboxItem>
      /** Row writes, committed with the op (row-backed domains). */
      readonly writes?: ReadonlyArray<RowWrite>
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
  /** `rows`: a read-only reader of the owner's rows in row mode (members out of the head, (f)); EMPTY_ROWS otherwise. */
  readonly authorize?: (state: S, op: string, params: P, principal: Principal, rows?: RowReader) => Reject | undefined
}
