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

/** Group roles (home-core conversation/roles.ts): one owner; admins manage people; read_only members only read. */
export const ParticipantRole = Schema.Literals(["owner", "admin", "member", "read_only"]).annotate({ identifier: "HomeParticipantRole" })
/** A role an op may grant (never owner: that is ownership.transfer). */
export const GrantableRole = Schema.Literals(["admin", "member", "read_only"]).annotate({ identifier: "HomeGrantableRole" })

export const Participant = Schema.Struct({
  id: ParticipantId,
  kind: Schema.Literals(["human", "agent", "address"]),
  display_name: Schema.String.check(Schema.isMaxLength(80)),
  agent_class: Schema.optionalKey(Schema.Literals(["mux", "agent"])),
  acp_session: Schema.optionalKey(Schema.String),
  owner_user: Schema.optionalKey(Schema.String),
  role: Schema.optionalKey(ParticipantRole),
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

/**
 * The owners count a link preview's title and site in code points and its URL in UTF-8 bytes
 * (cmux-conversation link_preview.rs, home-core link-preview.ts). The UTF-16 `isMaxLength`
 * beside each is only the loose bound JSON Schema can state (a code point is at most 2 units, a
 * URL has no more units than bytes); these filters are the rule.
 */
const maxCodePoints = (max: number) =>
  Schema.makeFilter((value: string) => [...value].length <= max || `at most ${max} characters`)
const utf8MaxBytes = (max: number) =>
  Schema.makeFilter((value: string) => new TextEncoder().encode(value).length <= max || `at most ${max} UTF-8 bytes`)

/** A derived image of an attachment (a video's poster, an image's preview): JPEG or WebP, capped per variant. */
const derivedImage = (identifier: string, maxBytes: number, description: string) =>
  Schema.Struct({
    hash: Sha256,
    mime_type: Schema.Literals(["image/jpeg", "image/webp"]),
    byte_count: Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0), Schema.isLessThanOrEqualTo(maxBytes))
  }).annotate({ identifier, description })

const cardUrl = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2048), utf8MaxBytes(2048))

/** card parts (home-core card.ts, https://github.com/manaflow-ai/cmux/issues/25830): only an agent posts one. */
const CardBrowser = Schema.Struct({
  type: Schema.Literal("card"),
  kind: Schema.Literal("browser"),
  surface: Schema.Literals(["browser", "computer"]),
  step: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(400), maxCodePoints(200)),
  live: Schema.optionalKey(Schema.Boolean),
  target: Schema.optionalKey(Schema.NullOr(Schema.String.check(Schema.isPattern(/^(browser:right|machine:[A-Za-z0-9_-]{1,128})$/)))),
  url: Schema.optionalKey(Schema.NullOr(cardUrl)),
  image: Schema.optionalKey(
    Schema.NullOr(
      Schema.Struct({
        hash: Sha256,
        mime_type: Schema.Literals(["image/png", "image/jpeg", "image/webp"]),
        byte_count: Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0), Schema.isLessThanOrEqualTo(4_194_304)),
        width: Schema.optionalKey(Schema.NullOr(Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0), Schema.isLessThanOrEqualTo(16_384)))),
        height: Schema.optionalKey(Schema.NullOr(Schema.Number.check(Schema.isInt(), Schema.isGreaterThan(0), Schema.isLessThanOrEqualTo(16_384))))
      }).annotate({
        identifier: "HomeCardImage",
        description: "A screenshot the agent uploaded to this conversation (intent, then PUT; image/png, image/jpeg or image/webp, at most 4 MiB); the owner refuses a hash it does not hold with the same type and size. Fetch it with POST /v1/home/attachments/url {hash: image.hash}."
      })
    )
  )
}).annotate({
  identifier: "HomePartCardBrowser",
  description: "A live browser or computer-use card. step is the current step (no control characters); live (default false) is true while the agent still drives; target is what Open opens (browser:right, or machine:<id> for a Cloud machine's desktop); the agent edits the card (message.edit) as steps change. Text fallback: \"Browser: <step>\" or \"Computer: <step>\"."
})

const CardSignIn = Schema.Struct({
  type: Schema.Literal("card"),
  kind: Schema.Literal("sign_in"),
  site: Schema.String.check(Schema.isPattern(/^[a-z0-9.-]*\.[a-z0-9.-]*$/), Schema.isMaxLength(253)),
  url: Schema.optionalKey(Schema.NullOr(cardUrl))
}).annotate({
  identifier: "HomePartCardSignIn",
  description: "A Secure Store card: the agent asks the person to save a sign-in for site (a lowercase DNS name) on their Mac; the password never enters the conversation. Text fallback: \"Secure Store: sign in to <site>\"."
})

const CardNextSteps = Schema.Struct({
  type: Schema.Literal("card"),
  kind: Schema.Literal("next_steps"),
  choices: Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(240), maxCodePoints(120))).check(Schema.isMinLength(1), Schema.isMaxLength(3))
}).annotate({
  identifier: "HomePartCardNextSteps",
  description: "Suggested next steps (1 to 3 distinct choices, no control characters). Tapping one sends a person message whose text is the choice. Text fallback: each choice on its own line after \"→ \"."
})

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
  }).annotate({ description: "A file uploaded to this conversation first (POST /v1/home/attachments/intent, then PUT the bytes); the owner refuses a hash it does not hold." }),
  Schema.Struct({
    type: Schema.Literal("link_preview"),
    url: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2048), utf8MaxBytes(2048)),
    // A null title, site or image is absent, as both owners read it (serde `Option`, link-preview.ts).
    title: Schema.optionalKey(Schema.NullOr(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(600), maxCodePoints(300)))),
    site: Schema.optionalKey(Schema.NullOr(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(506), maxCodePoints(253)))),
    image: Schema.optionalKey(Schema.NullOr(derivedImage("HomeLinkPreviewImage", 512_000, "An ordinary image attachment the sender uploaded to this conversation (intent, then PUT; image/jpeg or image/webp, at most 512000 bytes); the owner refuses a hash it does not hold with the same type and size. Fetch it with POST /v1/home/attachments/url {hash: image.hash}.")))
  }).annotate({ description: "A link with the preview its sender fetched; receivers render only from this part and never fetch the URL. url is http(s) with a host and no user info, at most 2048 UTF-8 bytes; title and site have no control characters." }),
  CardBrowser,
  CardSignIn,
  CardNextSteps
]).annotate({ identifier: "HomePart" })
export const Parts = Schema.Array(Part).check(Schema.isMinLength(1), Schema.isMaxLength(16))

export const PartRef = Schema.Struct({ message_id: MessageId, part_index: PartIndex }).annotate({ identifier: "HomePartRef" })

export const ReactionKind = Schema.Union([
  Schema.Struct({ tapback: Schema.Literals(["love", "like", "dislike", "laugh", "emphasize", "question"]) }),
  Schema.Struct({ emoji: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32)) })
]).annotate({ identifier: "HomeReactionKind" })

export const Reaction = Schema.Struct({ author: ParticipantId, part_index: PartIndex, kind: ReactionKind, at: Timestamp }).annotate({ identifier: "HomeReaction" })

export const ThreadStatus = Schema.Literals(["open", "resolved"]).annotate({ identifier: "HomeThreadStatus" })

/** The thread object a root message carries (thread.update, conversation-thread-objects-v1). */
export const ThreadState = Schema.Struct({
  title: Schema.optionalKey(Schema.String),
  owner: Schema.optionalKey(ParticipantId),
  resolved: Schema.optionalKey(Schema.Struct({ by: ParticipantId, at: Timestamp, seq: Seq }))
}).annotate({
  identifier: "HomeThreadState",
  description: "title, owner and resolution of a thread root. The thread reads as resolved only while no live reply has a seq above resolved.seq: a new reply reopens it."
})

export const Message = Schema.Struct({
  id: MessageId,
  conversation: ConversationId,
  seq: Seq,
  client_msg_id: ClientToken,
  author: ParticipantId,
  parts: Schema.Array(Part),
  reply_to: Schema.optionalKey(PartRef),
  thread_root: Schema.optionalKey(MessageId),
  thread: Schema.optionalKey(ThreadState),
  created_at: Timestamp,
  edited_at: Schema.optionalKey(Timestamp),
  retracted_at: Schema.optionalKey(Timestamp),
  reactions: Schema.Array(Reaction)
}).annotate({ identifier: "HomeMessage" })

/**
 * Thread stats of one root, computed by the owner at read time (cx-59n8.6): every reply counts,
 * a retracted one too; `authors` are the first 3 distinct reply authors by seq.
 */
export const ThreadSummary = Schema.Struct({
  root: MessageId,
  reply_count: Seq,
  last_reply_seq: Schema.NullOr(Seq),
  last_reply_at: Schema.NullOr(Timestamp),
  authors: Schema.Array(ParticipantId).check(Schema.isMaxLength(3)),
  status: Schema.optionalKey(ThreadStatus),
  title: Schema.optionalKey(Schema.String),
  owner: Schema.optionalKey(ParticipantId),
  resolved_by: Schema.optionalKey(ParticipantId),
  resolved_at: Schema.optionalKey(Timestamp)
}).annotate({
  identifier: "HomeThreadSummary",
  description: "status is derived (resolved while the root's resolution is newer than every live reply); title and owner come from the root's thread object; resolved_by and resolved_at only while resolved."
})

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
  retention_days: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(30))),
  member_count: Schema.optionalKey(Seq.annotate({ description: "A large group (more than 64 members): participants is a roster of at most 16 humans plus the owner and agents; this counts every current participant, and conversation.members pages them." }))
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
  large: Schema.optionalKey(Schema.Boolean.annotate({ description: "A large group: inbox.list pulls this row from the conversation, and the inbox stream bumps it only when you are named (a mention, your own message, being added or removed)." })),
  member_count: Schema.optionalKey(Seq),
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

