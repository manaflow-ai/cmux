import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { ConversationId, ConversationKind, InboxEntry, ParticipantId, Seq, Timestamp } from "./ops-home-schemas.ts"

/**
 * Inbox (UserDO stream `inbox:<user>`), chiefs (UserDO), the chief wake queue (MuxDO) and Home
 * search (PlanetScale projection), home-messaging.md sections 4.2, 4.3 and 8.
 */
const inboxErrors = [...mutationErrors, "unknown_conversation", "invalid_params", "forbidden"]
const AgentId = Schema.String.check(Schema.isPattern(/^agent_[A-Za-z0-9_.-]{1,64}$/)).annotate({ identifier: "AgentId" })

const inboxOp = (name: string, params: Schema.Top, docs: string) =>
  def({
    name,
    owner: "cloud:UserDO",
    class: "mutation",
    risk: "mutate-own",
    target: "inbox",
    principals: ["session", "install"],
    params,
    result: InboxEntry,
    errors: inboxErrors,
    docs,
    cli: { path: `inbox ${name.slice("inbox.".length).replace("_", "-")}`, visible: true },
    mcp: { expose: "opt_in", group: "home" }
  })

export const InboxPin = inboxOp(
  "inbox.pin",
  Schema.Struct({ conversation: ConversationId, pinned: Schema.Boolean, position: Schema.optionalKey(Seq) }),
  "Pin or unpin a conversation in your Home list."
)
export const InboxMute = inboxOp(
  "inbox.mute",
  Schema.Struct({ conversation: ConversationId, muted: Schema.Boolean, until: Schema.optionalKey(Schema.Number) }),
  "Mute a conversation (until a time in ms, or until unmuted). Approvals still notify."
)
export const InboxArchive = inboxOp(
  "inbox.archive",
  Schema.Struct({ conversation: ConversationId, archived: Schema.Boolean }),
  "Archive or unarchive a conversation; a new message unarchives it."
)
export const InboxMarkUnread = inboxOp(
  "inbox.mark_unread",
  Schema.Struct({ conversation: ConversationId, unread: Schema.Boolean }),
  "Flag a conversation unread (the read cursor stays)."
)

export const InboxList = def({
  name: "inbox.list",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "inbox",
  principals: ["session", "install"],
  params: Schema.Struct({
    limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(200))),
    include_archived: Schema.optionalKey(Schema.Boolean)
  }),
  result: Schema.Struct({ entries: Schema.Array(InboxEntry), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List your Home conversations: pinned first by position, then newest activity first.",
  cli: { path: "inbox list", visible: true },
  mcp: { expose: "default", group: "home" }
})

export const InboxDmPeer = def({
  name: "inbox.dm_peer",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "inbox",
  principals: ["session", "install"],
  params: Schema.Struct({ peer: ParticipantId }),
  result: Schema.Struct({ conversation: Schema.NullOr(ConversationId) }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Your existing one-to-one conversation with a peer, if any (dm.open checks it before deriving a new id).",
  cli: { path: "inbox dm-peer", visible: false },
  mcp: { expose: "never", group: "home" }
})

const ChiefName = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(60))
const Chief = Schema.Struct({
  agent: AgentId,
  owner_user: Schema.String,
  name: ChiefName,
  avatar: Schema.optionalKey(Schema.String),
  parent: Schema.optionalKey(AgentId),
  brain: Schema.Literals(["local", "cloud"]),
  thread: ConversationId,
  archived_at: Schema.optionalKey(Timestamp)
}).annotate({ identifier: "HomeChief" })

export const ChiefCreate = def({
  name: "chief.create",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "chief",
  principals: ["session"],
  params: Schema.Struct({
    name: ChiefName,
    parent: Schema.optionalKey(AgentId),
    avatar: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(1024))),
    brain: Schema.Literals(["local", "cloud"])
  }),
  result: Chief,
  errors: mutationErrors,
  docs: "Create a chief (or a subchief under parent): its agent principal and mux grant, its wake queue and its chief thread.",
  cli: { path: "chief create", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const ChiefUpdate = def({
  name: "chief.update",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "chief",
  principals: ["session"],
  params: Schema.Struct({ agent: AgentId, name: Schema.optionalKey(ChiefName), avatar: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(1024))) }),
  result: Chief,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Rename a chief or change its avatar.",
  cli: { path: "chief update", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const ChiefArchive = def({
  name: "chief.archive",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "destructive",
  target: "chief",
  principals: ["session"],
  params: Schema.Struct({ agent: AgentId }),
  result: Chief,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Archive a chief: its thread stays readable, it stops waking.",
  cli: { path: "chief archive", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const HomeSettingsSet = def({
  name: "home.settings.set",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "home_settings",
  principals: ["session"],
  params: Schema.Struct({
    discoverable_by_email: Schema.optionalKey(Schema.Boolean),
    discoverable_by_phone: Schema.optionalKey(Schema.Boolean),
    allow_dm_from: Schema.optionalKey(Schema.Literals(["anyone", "teams", "contacts"]))
  }),
  result: Schema.Struct({
    discoverable_by_email: Schema.Boolean,
    discoverable_by_phone: Schema.Boolean,
    allow_dm_from: Schema.Literals(["anyone", "teams", "contacts"])
  }),
  errors: mutationErrors,
  docs: "Choose who can find you by email or phone and who may start a DM with you.",
  cli: { path: "home settings", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const MuxAck = def({
  name: "mux.ack",
  owner: "cloud:MuxDO",
  class: "mutation",
  risk: "mutate-own",
  target: "chief",
  principals: ["install"],
  params: Schema.Struct({ agent: AgentId, conversation: ConversationId, seq: Seq.check(Schema.isGreaterThanOrEqualTo(1)) }),
  result: Schema.Struct({ cursor: Seq, cleared: Schema.optionalKey(Seq) }),
  errors: [...mutationErrors, "invalid_params"],
  docs: "The chief's brain host acknowledges its wakes in a conversation up to seq (moves its catch-up cursor).",
  cli: { path: "chief ack", visible: false },
  mcp: { expose: "never", group: "home" }
})

export const MuxConfigure = def({
  name: "mux.configure",
  owner: "cloud:MuxDO",
  class: "mutation",
  risk: "mutate-own",
  target: "chief",
  principals: ["session", "install"],
  params: Schema.Struct({ agent: AgentId, brain: Schema.Literals(["local", "cloud"]), brain_host: Schema.optionalKey(Schema.NullOr(Schema.String)) }),
  result: Schema.Unknown,
  errors: [...mutationErrors, "invalid_params"],
  docs: "Run a chief's brain locally (on a host) or in the cloud (the chief's owner).",
  cli: { path: "chief brain", visible: true },
  mcp: { expose: "never", group: "home" }
})

export const HomeSearch = def({
  name: "home.search",
  owner: "cloud:planetscale",
  class: "read",
  risk: "read",
  target: "message",
  principals: ["session", "install"],
  params: Schema.Struct({
    q: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
    conversation: Schema.optionalKey(ConversationId),
    author: Schema.optionalKey(ParticipantId),
    kind: Schema.optionalKey(ConversationKind),
    before: Schema.optionalKey(Timestamp),
    cursor: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(512))),
    limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(50)))
  }),
  result: Schema.Struct({
    hits: Schema.Array(
      Schema.Struct({
        conversation: ConversationId,
        seq: Seq,
        message_id: Schema.String,
        author: ParticipantId,
        created_at: Timestamp,
        snippet: Schema.String,
        ranges: Schema.Array(Schema.Struct({ start: Seq, length: Seq }))
      })
    ),
    cursor: Schema.optionalKey(Schema.String)
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "validation.invalid"],
  docs: "Search Home messages in conversations you are a current human participant of (newest first, with a short Top section).",
  cli: { path: "chat search", visible: true },
  mcp: { expose: "default", group: "home" }
})

export const homeInboxOps = [
  InboxPin,
  InboxMute,
  InboxArchive,
  InboxMarkUnread,
  InboxList,
  InboxDmPeer,
  ChiefCreate,
  ChiefUpdate,
  ChiefArchive,
  HomeSettingsSet,
  MuxAck,
  MuxConfigure,
  HomeSearch
] as const

const internal = (name: string, owner: CloudOpDef["owner"], target: string, docs: string): CloudOpDef =>
  ({
    name,
    owner,
    class: "mutation",
    risk: "mutate-own",
    target,
    principals: ["system"],
    params: Schema.Unknown,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/**
 * System ops built inside a Durable Object or by the Worker (DO-to-DO outbox, provider
 * webhooks, the invite flow). Never exported to the catalog (no HTTP, MCP or CLI surface);
 * params are validated by the home-core reducers.
 */
export const homeInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("inbox.bump", "cloud:UserDO", "inbox", "Internal: a ConversationDO projects one conversation into a participant's inbox (max-merge by rev)."),
  internal("invite.quota.take", "cloud:UserDO", "invite", "Internal: the Worker takes one invite from the inviter's windows before invite.create."),
  internal("mux.bind", "cloud:MuxDO", "chief", "Internal: binds a MuxDO to its chief and owner when the chief is created."),
  internal("mux.wake", "cloud:MuxDO", "chief", "Internal: a ConversationDO queues a wake for a chief."),
  internal("invite.delivery.report", "cloud:ConversationDO", "invite", "Internal: an AddressDO reports an invite's delivery state (forward only)."),
  internal("address.ensure", "cloud:AddressDO", "address", "Internal: stores a normalized address; returns its id, linked user and suppression."),
  internal("address.deliver", "cloud:AddressDO", "address", "Internal: sends an invite through the provider after the invite commit (suppression, limits, environment policy)."),
  internal("address.delivery.record", "cloud:AddressDO", "address", "Internal: records a provider delivery callback."),
  internal("address.link", "cloud:AddressDO", "address", "Internal: links an address to the user who accepted with it."),
  internal("address.suppress", "cloud:AddressDO", "address", "Internal: suppresses an address (opt-out, bounce, complaint, report)."),
  internal("address.unsuppress", "cloud:AddressDO", "address", "Internal: lifts a suppression for a session whose verified address is this one."),
  internal("address.stash_secret", "cloud:AddressDO", "address", "Internal: the Worker stashes an invite secret for rendering the link; deleted after send or 24 h, outside op state.")
]
