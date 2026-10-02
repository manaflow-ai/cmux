/**
 * Conversation wire types (plans/cmux-next/home.md section 2 and
 * home-messaging.md section 2). The JSON shape equals the Rust crate
 * `cmux-conversation`: snake_case fields, optional fields omitted when absent,
 * ops tagged by `kind`, changes tagged by kebab-case `kind`.
 *
 * Cloud extensions are optional fields. A head without `kind` is a local
 * conversation and follows the Rust rules exactly; a head with `kind` is a
 * cloud (or self-hosted) conversation and adds the cloud rules.
 */

export type ParticipantKind = "human" | "agent" | "contact"
export type AgentClass = "mux" | "agent"
export type ParticipantRole = "owner" | "member"
export type ConversationKind = "chief" | "dm" | "group"
export type ConversationState = "active" | "archived"

export interface Participant {
  /** `user_<id>`, `agent_<name>` or `contact_<26 base32>` (cloud). */
  readonly id: string
  readonly kind: ParticipantKind
  readonly display_name: string
  readonly agent_class?: AgentClass
  readonly acp_session?: string
  /** Cloud: the user an agent acts for. */
  readonly owner_user?: string
  /** Cloud: stamped by the owner. */
  readonly role?: ParticipantRole
  /** Cloud: `last_seq` when the participant was added. */
  readonly joined_seq?: number
  /** Cloud: who added the participant. */
  readonly added_by?: string
  /** Cloud: set when the participant left or was removed. */
  readonly left_at?: string
}

export interface PartRef {
  readonly message_id: string
  readonly part_index: number
}

/** A styled range of a text part, in UTF-16 code units. */
export interface TextRun {
  readonly start: number
  readonly length: number
  readonly mention?: string
  readonly link?: string
}

export type WorkStatus = "running" | "done" | "failed" | "waiting"

export type Part =
  | { readonly type: "text"; readonly text: string; readonly runs?: ReadonlyArray<TextRun> }
  | {
      readonly type: "work"
      readonly session: string
      readonly host?: string
      readonly status: WorkStatus
      readonly preview?: string
    }

export type Tapback = "love" | "like" | "dislike" | "laugh" | "emphasize" | "question"
export const TAPBACKS: ReadonlyArray<Tapback> = ["love", "like", "dislike", "laugh", "emphasize", "question"]

/** `{"tapback": "love"}` or `{"emoji": "🎉"}`. */
export type ReactionKind = { readonly tapback: Tapback } | { readonly emoji: string }

export interface Reaction {
  readonly author: string
  readonly part_index: number
  readonly kind: ReactionKind
  readonly at: string
}

export interface Message {
  readonly id: string
  readonly conversation: string
  /** 1-based and dense per conversation. */
  readonly seq: number
  readonly client_msg_id: string
  readonly author: string
  readonly parts: ReadonlyArray<Part>
  readonly reply_to?: PartRef
  readonly created_at: string
  readonly edited_at?: string
  readonly retracted_at?: string
  readonly reactions: ReadonlyArray<Reaction>
}

export type InviteChannel = "email" | "sms"
/**
 * `approval_pending`: a group email invite was opened by an account whose
 * verified email does not match; the inviter or the owner approves the join
 * (D-H4, decided 2026-10-02).
 */
export type InviteStatus = "pending" | "approval_pending" | "accepted" | "revoked" | "expired"
export type DeliveryState =
  | "queued"
  | "sent"
  | "delivered"
  | "bounced"
  | "complained"
  | "failed"
  | "suppressed"
  | "refused_env"

export interface Delivery {
  readonly state: DeliveryState
  readonly provider_id?: string
  readonly at: string
}

/** Cloud: an invite stored inside its conversation head. */
export interface Invite {
  /** `inv_<26>`. */
  readonly id: string
  /** `contact_<26>`. */
  readonly contact: string
  readonly channel: InviteChannel
  readonly display_name: string
  readonly invited_by: string
  readonly created_at: string
  readonly expires_at: string
  /** sha256 of the secret; never leaves the owner (stripped from summaries). */
  readonly token_hash: string
  readonly status: InviteStatus
  readonly accepted_by?: string
  readonly accepted_at?: string
  /** `approval_pending`: the user who asked to join, their name and when. */
  readonly requested_by?: string
  readonly requested_name?: string
  readonly requested_at?: string
  readonly delivery: Delivery
  readonly copy_variant: string
  readonly locale: string
}

/** What subscribers see of an invite: no token hash. */
export type PublicInvite = Omit<Invite, "token_hash">

export type WakePolicy = "auto" | "mentions" | "all"
export type HistoryVisible = "all" | "since_join"

export interface AgentBudgetSettings {
  readonly turns: number
  readonly gap_ms: number
}

export interface ConversationSettings {
  readonly wake_policy: WakePolicy
  readonly agent_budget: AgentBudgetSettings
  readonly history_visible: HistoryVisible
}

/** The conversation state every op validates against. */
export interface ConversationHead {
  readonly id: string
  readonly title: string
  readonly participants: ReadonlyArray<Participant>
  readonly last_seq: number
  /** Increases by exactly one per committed op. */
  readonly rev: number
  readonly created_at: string
  readonly updated_at: string
  readonly read_cursors: Readonly<Record<string, number>>
  // Cloud extensions (absent on a local head).
  readonly kind?: ConversationKind
  readonly team?: string
  readonly created_by?: string
  readonly state?: ConversationState
  readonly settings?: ConversationSettings
  readonly invites?: ReadonlyArray<Invite>
  readonly retention_days?: number
}

export interface Summary {
  readonly id: string
  /** `local` or `cloud`. */
  readonly owner: string
  readonly title: string
  readonly participants: ReadonlyArray<Participant>
  readonly last_seq: number
  readonly rev: number
  readonly created_at: string
  readonly updated_at: string
  readonly last_message?: Message
  readonly read_cursors: Readonly<Record<string, number>>
  // Cloud extensions.
  readonly kind?: ConversationKind
  readonly team?: string
  readonly created_by?: string
  readonly state?: ConversationState
  readonly settings?: ConversationSettings
  readonly invites?: ReadonlyArray<PublicInvite>
  readonly retention_days?: number
}

/** The local subset: the ops of the Rust crate. */
export type LocalOp =
  | { readonly kind: "message.send"; readonly client_msg_id: string; readonly parts: ReadonlyArray<Part>; readonly reply_to?: PartRef }
  | { readonly kind: "message.edit"; readonly message_id: string; readonly parts: ReadonlyArray<Part> }
  | { readonly kind: "message.retract"; readonly message_id: string }
  | { readonly kind: "reaction.add"; readonly message_id: string; readonly part_index: number; readonly reaction: ReactionKind }
  | { readonly kind: "reaction.remove"; readonly message_id: string; readonly part_index: number; readonly reaction: ReactionKind }
  | { readonly kind: "read_cursor.set"; readonly seq: number }
  | { readonly kind: "participants.add"; readonly participant: Participant }
  | { readonly kind: "title.set"; readonly title: string }

export interface InviteCreateParams {
  readonly kind: "invite.create"
  readonly invite_id: string
  /** The contact id from `contact.ensure`. */
  readonly contact: string
  readonly channel: InviteChannel
  /** How the inviter named the contact (never the raw address). */
  readonly display_name: string
  /** sha256 of the secret, computed by the host. */
  readonly token_hash: string
  readonly locale: string
  readonly copy_variant: string
}

/** Cloud extensions. */
export type CloudOp =
  | { readonly kind: "participants.remove"; readonly participant: string }
  | InviteCreateParams
  | { readonly kind: "invite.revoke"; readonly invite_id: string }
  | { readonly kind: "invite.accept"; readonly token_hash: string; readonly display_name: string }
  | { readonly kind: "invite.approve_join"; readonly invite_id: string }
  | { readonly kind: "invite.delivery.report"; readonly invite_id: string; readonly delivery: { readonly state: DeliveryState; readonly provider_id?: string } }
  | {
      readonly kind: "conversation.settings.set"
      readonly wake_policy?: WakePolicy
      readonly agent_budget?: AgentBudgetSettings
      readonly history_visible?: HistoryVisible
    }

export type Op = LocalOp | CloudOp
export type OpKind = Op["kind"]

/** What a committed op changed, carried by `conversation-changed`. */
export type Change =
  | { readonly kind: "message"; readonly message: Message }
  | { readonly kind: "message-updated"; readonly message: Message }
  | { readonly kind: "read-cursor"; readonly participant: string; readonly seq: number }
  | { readonly kind: "conversation"; readonly conversation: Summary }
  /** Cloud: an invite's delivery state moved. */
  | { readonly kind: "invite"; readonly conversation: string; readonly invite: PublicInvite }

/** The actor id of ops built inside a Durable Object (`invite.delivery.report`). */
export const SYSTEM_ACTOR = "system"
/** `Summary.owner` for conversations owned by a local daemon. */
export const OWNER_LOCAL = "local"
/** `Summary.owner` for cloud and self-hosted (cloud-shaped) conversations. */
export const OWNER_CLOUD = "cloud"

/** Most parts in one message. */
export const MAX_PARTS = 16
/** Most UTF-8 bytes of text across a message's text parts. */
export const MAX_TEXT_BYTES = 64 * 1024
/** Longest title, in characters. */
export const MAX_TITLE_CHARS = 200
/** Most current participants in one conversation. */
export const MAX_PARTICIPANTS = 64
/** Longest participant display name, in characters. */
export const MAX_DISPLAY_NAME_CHARS = 100
/** Most text runs in one text part. */
export const MAX_TEXT_RUNS = 1024
/** Longest work-part preview, in UTF-8 bytes. */
export const MAX_PREVIEW_BYTES = 4096
/** Longest emoji reaction, in UTF-8 bytes. */
export const MAX_EMOJI_BYTES = 64
/** Cloud: most pending invites per conversation. */
export const MAX_PENDING_INVITES = 20
/** Cloud: invite lifetime. */
export const INVITE_TTL_MS = 14 * 24 * 3600_000

export const DEFAULT_SETTINGS: ConversationSettings = {
  wake_policy: "auto",
  agent_budget: { turns: 4, gap_ms: 2_000 },
  history_visible: "all"
}
