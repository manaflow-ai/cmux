import { Schema } from "effect"
import { def } from "./op-def.ts"
import {
  ClientToken,
  ConversationCommit,
  ConversationId,
  conversationErrors,
  ConversationSettings,
  ConversationSummary,
  InviteId,
  Message,
  MessageId,
  ParticipantId,
  ParticipantInput,
  PartIndex,
  PartRef,
  Parts,
  ReactionKind,
  Seq
} from "./ops-home-schemas.ts"

/**
 * ConversationDO ops (home-messaging.md section 4.1), one object per conversation. Every op
 * except create and dm.open names its conversation in `conversation`; the Worker routes by it
 * and strips it before the domain runs. Ids, token hashes and proofs the domain needs
 * (conversation.create id, invite.create invite_id/address/token_hash, invite.accept proof) are
 * derived by the Worker from these public params, never sent by clients.
 */
const conv = { conversation: ConversationId }
const cli = (path: string) => ({ path: `chat ${path}`, visible: true })
const commit = ConversationCommit

const Title = Schema.String.check(Schema.isMaxLength(200))

export const ConversationCreate = def({
  name: "conversation.create",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({
    kind: Schema.optionalKey(Schema.Literal("group")),
    title: Schema.optionalKey(Title),
    participants: Schema.Array(ParticipantInput).check(Schema.isMaxLength(63)),
    settings: Schema.optionalKey(ConversationSettings)
  }),
  result: Schema.Struct({ conversation: ConversationSummary }),
  errors: [...conversationErrors, "conversation_exists", "invalid_participant", "invalid_title", "not_reachable", "home.rate_limited"],
  docs: "Create a group conversation. The Worker derives the id from the caller and the idempotency key, so a retry reaches the same conversation. At most 60 per hour per caller (home.rate_limited, with details.retry_after_ms).",
  cli: cli("create"),
  mcp: { expose: "default", group: "home" }
})

export const DmOpen = def({
  name: "dm.open",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({
    peer: Schema.Union([
      ParticipantId,
      Schema.Struct({ email: Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(254)) }),
      Schema.Struct({ phone: Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(32)) })
    ])
  }),
  result: Schema.Struct({ conversation: ConversationSummary }),
  errors: [...conversationErrors, "invalid_participant", "invite_limit", "not_reachable"],
  docs: "Open the one-to-one conversation with a user or chief, or with an email or phone (which invites the address). Idempotent: an existing DM with the peer is returned.",
  cli: cli("dm"),
  mcp: { expose: "default", group: "home" }
})

export const MessageSend = def({
  name: "message.send",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "message",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, client_msg_id: ClientToken, parts: Parts, reply_to: Schema.optionalKey(PartRef) }),
  result: commit,
  errors: [...conversationErrors, "invalid_parts", "invalid_client_msg_id", "idempotency_conflict", "agent_budget", "agent_rate", "address_cannot_act"],
  docs: "Send a message. client_msg_id must equal the idempotency key; a retry with the same key returns the original message.",
  cli: cli("send"),
  mcp: { expose: "default", group: "home" }
})

export const MessageEdit = def({
  name: "message.edit",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-own",
  target: "message",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, message_id: MessageId, parts: Parts }),
  result: commit,
  errors: [...conversationErrors, "not_author", "unknown_message", "retracted", "invalid_parts"],
  docs: "Replace the parts of one of your messages (not after it was retracted).",
  cli: cli("edit"),
  mcp: { expose: "default", group: "home" }
})

export const MessageRetract = def({
  name: "message.retract",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-own",
  target: "message",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, message_id: MessageId }),
  result: commit,
  errors: [...conversationErrors, "not_author", "unknown_message", "retracted"],
  docs: "Retract one of your messages: its parts and reactions are cleared and it leaves search.",
  cli: cli("retract"),
  mcp: { expose: "opt_in", group: "home" }
})

const reactionParams = Schema.Struct({ ...conv, message_id: MessageId, part_index: PartIndex, reaction: ReactionKind })

export const ReactionAdd = def({
  name: "reaction.add",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "message",
  principals: ["session", "install"],
  params: reactionParams,
  result: commit,
  errors: [...conversationErrors, "unknown_message", "invalid_part_index", "duplicate_reaction", "invalid_reaction", "retracted"],
  docs: "Add a tapback or emoji reaction to a message part (one per author, part and kind).",
  cli: cli("react"),
  mcp: { expose: "default", group: "home" }
})

export const ReactionRemove = def({
  name: "reaction.remove",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-own",
  target: "message",
  principals: ["session", "install"],
  params: reactionParams,
  result: commit,
  errors: [...conversationErrors, "unknown_message", "unknown_reaction"],
  docs: "Remove one of your reactions.",
  cli: cli("unreact"),
  mcp: { expose: "opt_in", group: "home" }
})

export const ReadCursorSet = def({
  name: "read_cursor.set",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-own",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, seq: Seq }),
  result: commit,
  errors: [...conversationErrors, "cursor_regression", "cursor_out_of_range"],
  docs: "Move your read cursor forward (monotonic, at most last_seq). Recommended key: read:<seq>.",
  cli: { path: "chat read", visible: false },
  mcp: { expose: "never", group: "home" }
})

export const TitleSet = def({
  name: "title.set",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, title: Title }),
  result: commit,
  errors: [...conversationErrors, "invalid_title"],
  docs: "Rename a group conversation (not a dm or chief thread).",
  cli: cli("title"),
  mcp: { expose: "opt_in", group: "home" }
})

export const ParticipantsAdd = def({
  name: "participants.add",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, participant: ParticipantInput }),
  result: commit,
  errors: [...conversationErrors, "duplicate_participant", "invalid_participant", "not_reachable", "home.rate_limited"],
  docs: "Add a user who shares a team with you or is connected to you, when their allow_requests_from setting allows it, or a chief its reachability allows (max 64). Anyone else needs invite.create. At most 120 per hour per caller (home.rate_limited, with details.retry_after_ms).",
  cli: cli("add"),
  mcp: { expose: "opt_in", group: "home" }
})

export const ParticipantsRemove = def({
  name: "participants.remove",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "destructive",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, participant: ParticipantId }),
  result: commit,
  errors: [...conversationErrors, "unknown_participant"],
  docs: "Leave (yourself), or remove a participant (conversation owner; a chief's owner for that chief). Removing the last human archives the conversation.",
  cli: cli("remove"),
  mcp: { expose: "never", group: "home" }
})

export const InviteCreate = def({
  name: "invite.create",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "send-external",
  target: "invite",
  principals: ["session", "install"],
  params: Schema.Struct({
    ...conv,
    address: Schema.Union([
      Schema.Struct({ email: Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(254)) }),
      Schema.Struct({ phone: Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(32)) })
    ]),
    display_name: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80)),
    locale: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(35))),
    copy_variant: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(16)))
  }),
  result: commit,
  errors: [...conversationErrors, "invite_limit", "invite_self", "duplicate_invite", "invalid_invite"],
  docs: "Invite an email or phone to the conversation. The Worker normalizes the address, checks limits and suppression, and the invite is sent by email or iMessage/SMS after the commit.",
  cli: cli("invite"),
  mcp: { expose: "opt_in", group: "home" }
})

export const InviteRevoke = def({
  name: "invite.revoke",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "invite",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, invite_id: InviteId }),
  result: commit,
  errors: [...conversationErrors, "unknown_invite", "invite_not_pending"],
  docs: "Revoke a pending invite (the inviter or the conversation owner).",
  cli: cli("invite revoke"),
  mcp: { expose: "opt_in", group: "home" }
})

export const InviteAccept = def({
  name: "invite.accept",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-own",
  target: "invite",
  principals: ["session"],
  params: Schema.Struct({
    code: Schema.String.check(Schema.isPattern(/^[dg][0-9A-HJKMNP-TV-Z]{26}$/)),
    secret: Schema.String.check(Schema.isPattern(/^[0-9A-HJKMNP-TV-Z]{26}$/))
  }),
  result: commit,
  errors: [...conversationErrors, "unknown_invite", "invite_not_pending", "invite_expired"],
  docs: "Accept an invite from its link (/i/<code>#<secret>). The Worker turns the secret into the proof the owner checks; a group invite may wait for the inviter's approval.",
  cli: { path: "chat accept", visible: false },
  mcp: { expose: "never", group: "home" }
})

export const InviteApproveJoin = def({
  name: "invite.approve_join",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "invite",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, invite_id: InviteId, approve: Schema.optionalKey(Schema.Boolean) }),
  result: commit,
  errors: [...conversationErrors, "unknown_invite", "invite_not_pending"],
  docs: "Approve (default) or decline a join that waits for approval (pending_approval).",
  cli: cli("invite approve"),
  mcp: { expose: "opt_in", group: "home" }
})

export const ConversationSettingsSet = def({
  name: "conversation.settings.set",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({
    ...conv,
    wake_policy: Schema.optionalKey(Schema.Literals(["auto", "mentions", "all"])),
    agent_budget: Schema.optionalKey(ConversationSettings.fields.agent_budget),
    history_visible: Schema.optionalKey(Schema.Literals(["all", "since_join"]))
  }),
  result: commit,
  errors: [...conversationErrors, "invalid_settings"],
  docs: "Change the chief wake policy, agent turn budget or history visibility (conversation owner).",
  cli: cli("settings"),
  mcp: { expose: "never", group: "home" }
})

export const ConversationSnapshot = def({
  name: "conversation.snapshot",
  owner: "cloud:ConversationDO",
  class: "read",
  risk: "read",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ ...conv, tail: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0), Schema.isLessThanOrEqualTo(200))) }),
  result: Schema.Struct({ conversation: ConversationSummary, messages: Schema.Array(Message), revision: Schema.String }),
  errors: [...conversationErrors],
  docs: "Read the conversation and its newest messages (history_visible since_join hides earlier ones).",
  cli: cli("show"),
  mcp: { expose: "default", group: "home" }
})

export const ConversationHistory = def({
  name: "conversation.history",
  owner: "cloud:ConversationDO",
  class: "read",
  risk: "read",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({
    ...conv,
    before_seq: Schema.optionalKey(Seq),
    limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(200)))
  }),
  result: Schema.Struct({ messages: Schema.Array(Message), next_before_seq: Schema.NullOr(Seq), revision: Schema.String }),
  errors: [...conversationErrors],
  docs: "Page older messages before before_seq (newest first within the page).",
  cli: cli("history"),
  mcp: { expose: "default", group: "home" }
})

export const ConversationImport = def({
  name: "conversation.import",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({
    id: Schema.optionalKey(ConversationId),
    source: Schema.optionalKey(Schema.Struct({ kind: Schema.Literal("mac"), host: Schema.String.check(Schema.isMaxLength(128)), local_id: Schema.String.check(Schema.isMaxLength(128)) })),
    kind: Schema.optionalKey(Schema.Literals(["group", "chief"])),
    title: Schema.optionalKey(Title),
    participants: Schema.optionalKey(Schema.Array(ParticipantInput).check(Schema.isMaxLength(64))),
    after_seq: Schema.optionalKey(Seq),
    messages: Schema.Array(Schema.Unknown).check(Schema.isMaxLength(500)),
    read_cursors: Schema.optionalKey(Schema.Unknown)
  }),
  result: commit,
  errors: [...conversationErrors, "conversation_exists", "import_out_of_order", "importing", "invalid_conversation_id"],
  docs: "Promote a Mac conversation (home-messaging.md section 22). The first call names its source; the Worker derives the id from the signed-in user and the source. Later calls send {id, after_seq, messages}. At most 500 messages and 1 MiB per batch.",
  cli: { path: "chat import", visible: false },
  mcp: { expose: "never", group: "home" }
})

export const ConversationImportCommit = def({
  name: "conversation.import.commit",
  owner: "cloud:ConversationDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "conversation",
  principals: ["session", "install"],
  params: Schema.Struct({ id: ConversationId, last_seq: Seq }),
  result: commit,
  errors: [...conversationErrors, "import_out_of_order"],
  docs: "Finish an import: read cursors are clamped, normal ops open, each human gets one inbox entry.",
  cli: { path: "chat import commit", visible: false },
  mcp: { expose: "never", group: "home" }
})

export const homeConversationOps = [
  ConversationImport,
  ConversationImportCommit,
  ConversationCreate,
  DmOpen,
  MessageSend,
  MessageEdit,
  MessageRetract,
  ReactionAdd,
  ReactionRemove,
  ReadCursorSet,
  TitleSet,
  ParticipantsAdd,
  ParticipantsRemove,
  InviteCreate,
  InviteRevoke,
  InviteAccept,
  InviteApproveJoin,
  ConversationSettingsSet,
  ConversationSnapshot,
  ConversationHistory
] as const
