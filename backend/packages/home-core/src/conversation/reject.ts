/**
 * Stable reject codes. The first twenty are the Rust crate's
 * `Reject::code()` values in the same order; the rest are cloud extensions.
 */
export const LOCAL_REJECT_CODES = [
  "not_participant",
  "not_author",
  "unknown_message",
  "invalid_parts",
  "idempotency_conflict",
  "cursor_regression",
  "unknown_conversation",
  "cursor_out_of_range",
  "retracted",
  "invalid_client_msg_id",
  "invalid_part_index",
  "duplicate_reaction",
  "unknown_reaction",
  "invalid_reaction",
  "duplicate_participant",
  "invalid_participant",
  "invalid_title",
  "agent_budget",
  "agent_rate",
  "actor_mismatch"
] as const

export const CLOUD_REJECT_CODES = [
  /** A address (not yet a user) tried to act. */
  "address_cannot_act",
  /** The conversation is archived (no human participant is left). */
  "archived",
  "importing",
  "conversation_exists",
  "import_out_of_order",
  "invalid_import",
  /** The actor may not run this op (not the owner, inviter, or system). */
  "forbidden",
  /** The op does not apply to this conversation kind (for example `title.set` on a dm). */
  "kind_forbids",
  /** A cloud-only op on a local head. */
  "unsupported_op",
  /** The named participant is not a current participant. */
  "unknown_participant",
  /** A dm id does not equal `dmConversationId` of its two participants. */
  "invalid_conversation_id",
  "unknown_invite",
  /** The invite was accepted or revoked already (single use). */
  "invite_not_pending",
  "invite_expired",
  /** The inviter tried to accept their own invite. */
  "invite_self",
  /** The invite id exists, or the address already has a pending invite here. */
  "duplicate_invite",
  /** Too many pending invites in this conversation. */
  "invite_limit",
  /** Malformed invite params. */
  "invalid_invite",
  /** A delivery report would move the delivery state backwards. */
  "delivery_regression",
  "invalid_settings",
  /** A human the actor may not reach (no shared team or connection, their settings, or a block); also an unknown account (section 16). */
  "not_reachable"
] as const

export type LocalRejectCode = (typeof LOCAL_REJECT_CODES)[number]
export type CloudRejectCode = (typeof CLOUD_REJECT_CODES)[number]
export type RejectCode = LocalRejectCode | CloudRejectCode

export const REJECT_CODES: ReadonlyArray<RejectCode> = [...LOCAL_REJECT_CODES, ...CLOUD_REJECT_CODES]

/** A refused op. Like the Rust `Err(Reject)`, it carries only the stable code. */
export interface ConversationReject {
  readonly ok: false
  readonly code: RejectCode
}

export const reject = (code: RejectCode): ConversationReject => ({ ok: false, code })

/** Thrown inside the reducer and caught at its boundary, so validation reads like Rust's `?`. */
export class RejectError extends Error {
  readonly code: RejectCode
  constructor(code: RejectCode) {
    super(code)
    this.code = code
  }
}

export const fail = (code: RejectCode): never => {
  throw new RejectError(code)
}
