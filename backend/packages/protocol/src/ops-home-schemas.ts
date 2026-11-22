import { Schema } from "effect"

/**
 * Home messaging wire schemas (plans/cmux-next/home-messaging.md sections 2 and 4), matching
 * backend/packages/home-core (conversation/types.ts, inbox/reducer.ts, mux/domain.ts). Ops are
 * in ops-home-conversation.ts (ConversationDO) and ops-home-inbox.ts (UserDO inbox, chiefs,
 * MuxDO, search, internal system ops).
 */

const CROCKFORD26 = "[0-9A-HJKMNP-TV-Z]{26}"
export const ConversationId = Schema.String.check(Schema.isPattern(new RegExp(`^conv_(dm_)?${CROCKFORD26}$`))).annotate({
  identifier: "ConversationId",
  description: "conv_<26> (group or chief) or conv_dm_<26> (one-to-one, derived from the pair)."
})
/** Engine-minted (`msg_` + 20 hex) or ULID-style (`msg_<26>`, local conversations). */
export const MessageId = Schema.String.check(Schema.isPattern(/^msg_[0-9A-Za-z]{1,64}$/)).annotate({ identifier: "MessageId" })
export const InviteId = Schema.String.check(Schema.isPattern(new RegExp(`^inv_${CROCKFORD26}$`))).annotate({ identifier: "InviteId" })
export const AddressId = Schema.String.check(Schema.isPattern(new RegExp(`^addr_${CROCKFORD26}$`))).annotate({
  identifier: "AddressId",
  description: "HMAC id of a normalized email or phone; never the raw address."
})
export const ParticipantId = Schema.String.check(Schema.isPattern(new RegExp(`^((user|agent)_[A-Za-z0-9_.-]{1,64}|addr_${CROCKFORD26})$`))).annotate({
  identifier: "ParticipantId",
  description: "user_<id>, agent_<name> or addr_<26> (an invited address)."
})
export const ClientToken = Schema.String.check(Schema.isPattern(/^[\x21-\x7e]{1,128}$/)).annotate({
  identifier: "ClientToken",
  description: "1 to 128 printable ASCII characters (idempotency key, client_msg_id)."
})
/** RFC 3339 UTC with milliseconds. */
export const Timestamp = Schema.String.annotate({ identifier: "Timestamp", description: "RFC 3339 UTC with milliseconds." })
export const Seq = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))
export const PartIndex = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0), Schema.isLessThan(16))

export const ConversationKind = Schema.Literals(["chief", "dm", "group"]).annotate({ identifier: "ConversationKind" })

export const Participant = Schema.Struct({
  id: ParticipantId,
  kind: Schema.Literals(["human", "agent", "address"]),
  display_name: Schema.String.check(Schema.isMaxLength(80)),
  agent_class: Schema.optionalKey(Schema.Literals(["mux", "agent"])),
  acp_session: Schema.optionalKey(Schema.String),
  owner_user: Schema.optionalKey(Schema.String),
  role: Schema.optionalKey(Schema.Literals(["owner", "member"])),
  joined_seq: Schema.optionalKey(Seq),
  added_by: Schema.optionalKey(Schema.String),
  left_at: Schema.optionalKey(Timestamp)
}).annotate({ identifier: "HomeParticipant" })

/** A participant to add: the owner stamps role, joined_seq and added_by. */
export const ParticipantInput = Schema.Struct({
  id: ParticipantId,
  kind: Schema.Literals(["human", "agent"]),
  display_name: Schema.String.check(Schema.isMaxLength(80)),
  agent_class: Schema.optionalKey(Schema.Literals(["mux", "agent"])),
  owner_user: Schema.optionalKey(Schema.String)
}).annotate({ identifier: "HomeParticipantInput" })

export const TextRun = Schema.Struct({
  start: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0)),
  length: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0)),
  mention: Schema.optionalKey(ParticipantId),
  link: Schema.optionalKey(Schema.String)
}).annotate({ identifier: "HomeTextRun", description: "A styled range of a text part, in UTF-16 code units." })

const Sha256 = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)).annotate({ identifier: "HomeSha256", description: "SHA-256 of the bytes, lowercase hex." })

/** A derived image of an attachment (a video's poster, an image's preview): JPEG or WebP, capped per variant. */
const derivedImage = (identifier: string, maxBytes: number, description: string) =>
  Schema.Struct({
    hash: Sha256,
    mime_type: Schema.Literals(["image/jpeg", "image/webp"]),
    byte_count: Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0), Schema.isLessThanOrEqualTo(maxBytes))
  }).annotate({ identifier, description })

export const Part = Schema.Union([
  Schema.Struct({ type: Schema.Literal("text"), text: Schema.String, runs: Schema.optionalKey(Schema.Array(TextRun)) }),
  Schema.Struct({
    type: Schema.Literal("work"),
    session: Schema.String,
    host: Schema.optionalKey(Schema.String),
    status: Schema.Literals(["running", "done", "failed", "waiting"]),
    preview: Schema.optionalKey(Schema.String)
  }),
  Schema.Struct({
    type: Schema.Literal("attachment"),
    hash: Sha256,
    name: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(255)),
    mime_type: Schema.String.check(Schema.isMaxLength(255)),
    byte_count: Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0)),
    width: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0))),
    height: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0))),
    duration_ms: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))),
    poster: Schema.optionalKey(derivedImage("HomeAttachmentPoster", 2_000_000, "Video only: the poster image uploaded with the video's slot (intent `poster`, then PUT to `poster_upload`); it must equal the one the video's record holds. Fetch it with POST /v1/home/attachments/url {variant: \"poster\"}.")),
    preview: Schema.optionalKey(derivedImage("HomeAttachmentPreview", 512_000, "Image only: a small preview uploaded with the image's slot (intent `preview`, then PUT to `preview_upload`); it must equal the one the image's record holds. Fetch it with POST /v1/home/attachments/url {variant: \"preview\"}."))
  }).annotate({ description: "A file uploaded to this conversation first (POST /v1/home/attachments/intent, then PUT the bytes); the owner refuses a hash it does not hold." })
]).annotate({ identifier: "HomePart" })
export const Parts = Schema.Array(Part).check(Schema.isMinLength(1), Schema.isMaxLength(16))

export const PartRef = Schema.Struct({ message_id: MessageId, part_index: PartIndex }).annotate({ identifier: "HomePartRef" })

export const ReactionKind = Schema.Union([
  Schema.Struct({ tapback: Schema.Literals(["love", "like", "dislike", "laugh", "emphasize", "question"]) }),
  Schema.Struct({ emoji: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32)) })
]).annotate({ identifier: "HomeReactionKind" })

export const Reaction = Schema.Struct({ author: ParticipantId, part_index: PartIndex, kind: ReactionKind, at: Timestamp }).annotate({ identifier: "HomeReaction" })

export const Message = Schema.Struct({
  id: MessageId,
  conversation: ConversationId,
  seq: Seq,
  client_msg_id: ClientToken,
  author: ParticipantId,
  parts: Schema.Array(Part),
  reply_to: Schema.optionalKey(PartRef),
  created_at: Timestamp,
  edited_at: Schema.optionalKey(Timestamp),
  retracted_at: Schema.optionalKey(Timestamp),
  reactions: Schema.Array(Reaction)
}).annotate({ identifier: "HomeMessage" })

export const DeliveryState = Schema.Literals(["queued", "sent", "delivered", "bounced", "complained", "failed", "suppressed", "refused_env"]).annotate({ identifier: "HomeDeliveryState" })

/** An invite as participants see it: no token hash. */
export const PublicInvite = Schema.Struct({
  id: InviteId,
  address: AddressId,
  channel: Schema.Literals(["email", "sms"]),
  display_name: Schema.String,
  invited_by: ParticipantId,
  created_at: Timestamp,
  expires_at: Timestamp,
  status: Schema.Literals(["pending", "pending_approval", "accepted", "revoked", "expired"]),
  accepted_by: Schema.optionalKey(Schema.String),
  accepted_at: Schema.optionalKey(Timestamp),
  requested_by: Schema.optionalKey(Schema.String),
  requested_name: Schema.optionalKey(Schema.String),
  requested_at: Schema.optionalKey(Timestamp),
  delivery: Schema.Struct({ state: DeliveryState, provider_id: Schema.optionalKey(Schema.String), at: Timestamp }),
  copy_variant: Schema.String,
  locale: Schema.String
}).annotate({ identifier: "HomeInvite" })

export const ConversationSettings = Schema.Struct({
  wake_policy: Schema.Literals(["auto", "mentions", "all"]),
  agent_budget: Schema.Struct({
    turns: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(16)),
    gap_ms: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0), Schema.isLessThanOrEqualTo(600_000))
  }),
  history_visible: Schema.Literals(["all", "since_join"])
}).annotate({ identifier: "HomeConversationSettings" })

/** What every participant may see of a conversation (home-core `Summary`). */
export const ConversationSummary = Schema.Struct({
  id: ConversationId,
  owner: Schema.String,
  title: Schema.String,
  participants: Schema.Array(Participant),
  last_seq: Seq,
  rev: Seq,
  created_at: Timestamp,
  updated_at: Timestamp,
  last_message: Schema.optionalKey(Message),
  read_cursors: Schema.Record(Schema.String, Seq),
  kind: Schema.optionalKey(ConversationKind),
  team: Schema.optionalKey(Schema.String),
  created_by: Schema.optionalKey(Schema.String),
  state: Schema.optionalKey(Schema.Literals(["active", "archived"])),
  settings: Schema.optionalKey(ConversationSettings),
  invites: Schema.optionalKey(Schema.Array(PublicInvite)),
  retention_days: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(30)))
}).annotate({ identifier: "HomeConversationSummary" })

/** The owner's answer to a conversation mutation (home-core domain `value`). */
export const ConversationCommit = Schema.Struct({
  rev: Seq,
  seq: Schema.optionalKey(Seq),
  message_id: Schema.optionalKey(MessageId),
  change: Schema.Unknown
}).annotate({ identifier: "HomeConversationCommit", description: "rev after the op; seq and message_id for a new message; change is the committed Change." })

export const InboxEntry = Schema.Struct({
  conversation: ConversationId,
  rev: Seq,
  kind: ConversationKind,
  title: Schema.String,
  last_seq: Seq,
  last_at: Timestamp,
  preview: Schema.String,
  preview_attachments: Schema.optionalKey(
    Schema.Struct({ kind: Schema.Literals(["photo", "video", "audio", "file"]), count: Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0)) }).annotate({
      description: "Attachments of the last message, for a localized preview (\"2 photos\"); preview is empty for an attachment-only message."
    })
  ),
  dm_peer: Schema.optionalKey(ParticipantId),
  removed: Schema.Boolean,
  unread: Seq,
  mentions: Seq,
  counts_rev: Seq,
  pinned: Schema.Boolean,
  pin_position: Schema.optionalKey(Seq),
  muted: Schema.Boolean,
  muted_until: Schema.optionalKey(Schema.Number),
  archived: Schema.Boolean,
  archived_seq: Seq,
  marked_unread: Schema.Boolean
}).annotate({ identifier: "HomeInboxEntry" })

/** Errors every conversation op may return: the shared codes plus home-core's reject codes. */
export const conversationErrors = [
  "validation.invalid",
  "idempotency.conflict",
  "auth.forbidden",
  "auth.unauthenticated",
  "owner.unreachable",
  "unknown_conversation",
  "not_participant",
  "forbidden",
  "archived",
  "kind_forbids"
]

