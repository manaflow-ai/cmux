import { Schema } from "effect"
import { FeedAttachment } from "./feed-kinds.ts"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"

/**
 * The feed (plans/cmux-next/feed.md): one per-user list of notices and
 * requests, owned by FeedDO (decision N10). Times are ms since the epoch.
 */

const Text = (max: number) => Schema.String.check(Schema.isMaxLength(max))
const NonEmpty = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))
const Int = (minimum: number, maximum: number) => Schema.Int.check(Schema.isBetween({ minimum, maximum }))
const List = <S extends Schema.Top>(item: S, min: number, max: number) => Schema.Array(item).check(Schema.isMinLength(min), Schema.isMaxLength(max))

export const FeedItemId = Schema.String.check(Schema.isPattern(/^fi_[a-z0-9]{20}$/)).annotate({
  identifier: "FeedItemId",
  description: "A feed item; stable when its home moves from a local owner to the cloud."
})
export const FeedKind = Schema.String.check(
  Schema.isPattern(/^(notice|question|choice|approve|confirm|sign-in|passkey|review|input|file|handoff|x-[a-z0-9][a-z0-9-]{0,39}\.[a-z0-9][a-z0-9-]{0,39})$/)
).annotate({ identifier: "FeedKind", description: "notice, a built-in request kind, or a custom kind x-<publisher>.<name>." })
export const FeedPriority = Schema.Literals(["low", "normal", "high", "urgent"]).annotate({ identifier: "FeedPriority" })
export const FeedState = Schema.Literals(["open", "answered", "cancelled", "expired"]).annotate({ identifier: "FeedState" })
export const FeedCancelReason = Schema.Literals(["poster", "declined", "answered_elsewhere", "superseded", "poster_gone"]).annotate({ identifier: "FeedCancelReason" })
export const FeedPosterKind = Schema.Literals(["agent", "harness", "app", "server", "vm", "automation", "integration", "system", "user"]).annotate({ identifier: "FeedPosterKind" })

/**
 * What selecting the item opens, run by the client with origin user. Only
 * open-style actions are allowed, so a poster can never make a click close or
 * run something.
 */
export const FeedOpen = Schema.Struct({
  action: Schema.Literals(["tab.focus", "workspace.focus", "browser.open", "browser.duplicateRight", "url.open", "task.open", "acp.session.open", "app.open"]),
  args: Schema.Record(Schema.String, Schema.Unknown)
}).annotate({ identifier: "FeedOpen" })

/** A selector for bulk triage and lists (instead of item ids). */
export const FeedFilter = Schema.Struct({
  poster_kind: Schema.optionalKey(FeedPosterKind),
  thread: Schema.optionalKey(NonEmpty(200)),
  workspace: Schema.optionalKey(NonEmpty(128)),
  kind: Schema.optionalKey(FeedKind)
}).annotate({ identifier: "FeedFilter" })

export const FeedContext = Schema.Struct({
  host: Schema.optionalKey(NonEmpty(128)),
  workspace: Schema.optionalKey(NonEmpty(128)),
  tab: Schema.optionalKey(NonEmpty(128)),
  terminal: Schema.optionalKey(NonEmpty(128)),
  browser_tab: Schema.optionalKey(NonEmpty(128)),
  acp_session: Schema.optionalKey(NonEmpty(128)),
  task: Schema.optionalKey(NonEmpty(128)),
  url: Schema.optionalKey(NonEmpty(2048))
}).annotate({ identifier: "FeedContext", description: "What the item is about; clients open it and use it for the visibility rule." })

export const FeedAction = Schema.Struct({
  id: NonEmpty(40),
  label: NonEmpty(40),
  style: Schema.optionalKey(Schema.Literals(["default", "primary", "destructive"])),
  /** A button that answers the request with this value (validated at post time). */
  answer: Schema.optionalKey(Schema.Unknown)
}).annotate({ identifier: "FeedAction" })

export const FeedPoster = Schema.Struct({
  kind: FeedPosterKind,
  /** The poster scope: dedupe keys, threads and agent reads are scoped to it. */
  scope: Schema.String,
  label: Text(80),
  install: Schema.optionalKey(Schema.String),
  agent: Schema.optionalKey(Schema.String),
  harness: Schema.optionalKey(NonEmpty(40))
}).annotate({ identifier: "FeedPoster" })

export const FeedItem = Schema.Struct({
  id: FeedItemId,
  home: Schema.String,
  type: Schema.Literals(["notice", "request"]),
  kind: FeedKind,
  title: NonEmpty(200),
  body: Text(4096),
  prompt: Schema.optionalKey(Schema.Unknown),
  answer_schema: Schema.optionalKey(Schema.Unknown),
  priority: FeedPriority,
  dedupe_key: Schema.NullOr(Schema.String),
  thread: Schema.NullOr(Schema.String),
  context: FeedContext,
  attachments: Schema.Array(FeedAttachment),
  actions: Schema.Array(FeedAction),
  open: Schema.NullOr(FeedOpen),
  poster: FeedPoster,
  state: FeedState,
  answer: Schema.NullOr(Schema.Struct({ value: Schema.Unknown, by: Schema.String, device: Schema.NullOr(Schema.String), at: Schema.Int })),
  cancel: Schema.NullOr(Schema.Struct({ reason: FeedCancelReason, by: Schema.String, at: Schema.Int, note: Schema.NullOr(Schema.String) })),
  needs_mac: Schema.Boolean,
  expires_at: Schema.Int,
  read_at: Schema.NullOr(Schema.Int),
  seen_at: Schema.NullOr(Schema.Int),
  archived_at: Schema.NullOr(Schema.Int),
  snoozed_until: Schema.NullOr(Schema.Int),
  push_due_at: Schema.NullOr(Schema.Int),
  pushed_at: Schema.NullOr(Schema.Int),
  count: Schema.Int,
  order: Schema.Int,
  revision: Schema.Int,
  created_at: Schema.Int,
  updated_at: Schema.Int,
  closed_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "FeedItem", description: "One notice or request in a user's feed." })
export type FeedItem = typeof FeedItem.Type

export const FeedPrefs = Schema.Struct({
  push_enabled: Schema.Boolean,
  /** Push delay per priority in ms; null never pushes that priority. */
  push_delay: Schema.Struct({ urgent: Schema.NullOr(Schema.Int), high: Schema.NullOr(Schema.Int), normal: Schema.NullOr(Schema.Int), low: Schema.NullOr(Schema.Int) }),
  push_skip_when_mac_active: Schema.Boolean
}).annotate({ identifier: "FeedPrefs", description: "Per-user push rules, synced by the feed owner." })
export type FeedPrefs = typeof FeedPrefs.Type

const MIN_EXPIRY = 10_000
const MAX_EXPIRY = 30 * 24 * 3600_000
const Items = List(FeedItemId, 1, 256)
const feedErrors = [...mutationErrors, "selector.not_found", "feed.closed", "feed.full", "feed.rate_limited", "feed.moving", "owner.moved"]
const ItemResult = Schema.Struct({ item: FeedItem })
const ItemsResult = Schema.Struct({ items: Schema.Array(FeedItem) })

export const FeedPost = def({
  name: "feed.post",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({
    type: Schema.Literals(["notice", "request"]),
    kind: FeedKind,
    title: NonEmpty(200),
    body: Schema.optionalKey(Text(4096)),
    prompt: Schema.optionalKey(Schema.Unknown),
    answer_schema: Schema.optionalKey(Schema.Unknown),
    priority: Schema.optionalKey(FeedPriority),
    dedupe_key: Schema.optionalKey(NonEmpty(200)),
    thread: Schema.optionalKey(NonEmpty(200)),
    context: Schema.optionalKey(FeedContext),
    attachments: Schema.optionalKey(List(FeedAttachment, 0, 8)),
    actions: Schema.optionalKey(List(FeedAction, 0, 4)),
    open: Schema.optionalKey(FeedOpen),
    expires_in_ms: Schema.optionalKey(Int(MIN_EXPIRY, MAX_EXPIRY)),
    poster: Schema.optionalKey(
      Schema.Struct({
        kind: Schema.optionalKey(FeedPosterKind),
        label: Schema.optionalKey(Text(80)),
        /** The agent a daemon posts for (its launch credential); scopes dedupe and reads. */
        agent: Schema.optionalKey(NonEmpty(128)),
        harness: Schema.optionalKey(NonEmpty(40))
      })
    )
  }),
  result: Schema.Struct({ item: FeedItem, deduped: Schema.Boolean }),
  errors: feedErrors,
  docs: "Post a notice or a request to the user's feed. A request waits for one answer from the user (use feed.watch or --wait).",
  cli: { path: "feed post", visible: true },
  mcp: { expose: "default", group: "feed" }
})

export const FeedAnswer = def({
  name: "feed.answer",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({ item: FeedItemId, answer: Schema.Unknown, device: Schema.optionalKey(Text(80)) }),
  result: ItemResult,
  errors: feedErrors,
  docs: "Answer an open request (the user only, origin user). The first answer wins; a closed item is refused with feed.closed.",
  cli: { path: "feed answer", visible: true },
  mcp: { expose: "never", group: "feed" }
})

export const FeedCancel = def({
  name: "feed.cancel",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({ item: FeedItemId, reason: Schema.optionalKey(FeedCancelReason), note: Schema.optionalKey(Text(500)) }),
  result: ItemResult,
  errors: feedErrors,
  docs: "Cancel an open item: its poster withdraws it, an adapter reports it answered elsewhere, or the user declines it.",
  cli: { path: "feed cancel", visible: true },
  mcp: { expose: "default", group: "feed" }
})

const triage = (name: string, docs: string, cli: string, extra: Schema.Struct.Fields = {}) =>
  def({
    name,
    owner: "cloud:FeedDO",
    class: "mutation",
    risk: "mutate-own",
    target: "feed_item",
    principals: ["session", "install"],
    params: Schema.Struct({ items: Items, ...extra }),
    result: ItemsResult,
    errors: feedErrors,
    docs,
    cli: { path: cli, visible: true },
    mcp: { expose: "never", group: "feed" }
  })

export const FeedRead = def({
  name: "feed.read",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({ items: Schema.optionalKey(Items), all: Schema.optionalKey(Schema.Boolean), filter: Schema.optionalKey(FeedFilter) }),
  result: ItemsResult,
  errors: feedErrors,
  docs: "Mark items read (the user opened or acknowledged them): by ids, by a filter, or `all` unread items.",
  cli: { path: "feed read", visible: true },
  mcp: { expose: "never", group: "feed" }
})
export const FeedSeen = triage("feed.seen", "Report items the user saw in view (a client's visibility rule); seen items do not push.", "feed seen")
export const FeedArchive = def({
  name: "feed.archive",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({ items: Schema.optionalKey(Items), filter: Schema.optionalKey(FeedFilter) }),
  result: ItemsResult,
  errors: feedErrors,
  docs: "Archive items (done) by ids or a filter. Open requests cannot be archived: answer or decline them (a filter skips them).",
  cli: { path: "feed archive", visible: true },
  mcp: { expose: "never", group: "feed" }
})
export const FeedUnarchive = triage("feed.unarchive", "Move archived items back to the active list.", "feed unarchive")
export const FeedSnooze = triage("feed.snooze", "Hide items until a time; they come back unread. Open requests cannot be snoozed.", "feed snooze", {
  until: Schema.Int
})

export const FeedPrefsSet = def({
  name: "feed.prefs.set",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed",
  principals: ["session", "install"],
  params: Schema.Struct({
    push_enabled: Schema.optionalKey(Schema.Boolean),
    push_delay: Schema.optionalKey(
      Schema.Struct({
        urgent: Schema.optionalKey(Schema.NullOr(Int(0, 24 * 3600_000))),
        high: Schema.optionalKey(Schema.NullOr(Int(0, 24 * 3600_000))),
        normal: Schema.optionalKey(Schema.NullOr(Int(0, 24 * 3600_000))),
        low: Schema.optionalKey(Schema.NullOr(Int(0, 24 * 3600_000)))
      })
    ),
    push_skip_when_mac_active: Schema.optionalKey(Schema.Boolean)
  }),
  result: Schema.Struct({ prefs: FeedPrefs }),
  errors: mutationErrors,
  docs: "Change the user's synced push rules.",
  cli: { path: "feed prefs set", visible: true },
  mcp: { expose: "never", group: "feed" }
})

export const FeedAdopt = def({
  name: "feed.adopt",
  owner: "cloud:FeedDO",
  class: "mutation",
  risk: "mutate-own",
  target: "feed_item",
  principals: ["install"],
  params: Schema.Struct({ item: FeedItem }),
  result: ItemResult,
  errors: feedErrors,
  docs: "Handoff: a daemon's local feed owner moves one of its items (same id) to the cloud owner after a reconnect.",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "feed" }
})

export const FeedList = def({
  name: "feed.list",
  owner: "cloud:FeedDO",
  class: "read",
  risk: "read",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({
    state: Schema.optionalKey(Schema.Literals(["open", "closed", "all"])),
    type: Schema.optionalKey(Schema.Literals(["notice", "request"])),
    kind: Schema.optionalKey(FeedKind),
    unread: Schema.optionalKey(Schema.Boolean),
    archived: Schema.optionalKey(Schema.Boolean),
    thread: Schema.optionalKey(NonEmpty(200)),
    needs_response: Schema.optionalKey(Schema.Boolean),
    poster_kind: Schema.optionalKey(FeedPosterKind),
    workspace: Schema.optionalKey(NonEmpty(128)),
    query: Schema.optionalKey(NonEmpty(200)),
    /** urgent (default): open requests by priority then age, then unread, then the rest newest first; recent: newest first. */
    order: Schema.optionalKey(Schema.Literals(["urgent", "recent"])),
    group_by: Schema.optionalKey(Schema.Literals(["thread", "poster", "workspace"])),
    /** Page after this item (the last id of the previous page). */
    after: Schema.optionalKey(FeedItemId),
    limit: Schema.optionalKey(Int(1, 500))
  }),
  result: Schema.Struct({
    items: Schema.Array(FeedItem),
    groups: Schema.optionalKey(Schema.Array(Schema.Struct({ key: Schema.String, label: Schema.String, items: Schema.Array(FeedItemId) }))),
    next: Schema.NullOr(FeedItemId),
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List feed items in the owner's order (one order for every client), optionally grouped. An agent sees only the items it posted.",
  cli: { path: "feed list", visible: true },
  mcp: { expose: "default", group: "feed" }
})

export const FeedGet = def({
  name: "feed.get",
  owner: "cloud:FeedDO",
  class: "read",
  risk: "read",
  target: "feed_item",
  principals: ["session", "install"],
  params: Schema.Struct({ item: FeedItemId }),
  result: ItemResult,
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read one feed item (its answer once it is answered). An agent reads only the items it posted.",
  cli: { path: "feed get", visible: true },
  mcp: { expose: "default", group: "feed" }
})

export const FeedCounts = def({
  name: "feed.counts",
  owner: "cloud:FeedDO",
  class: "read",
  risk: "read",
  target: "feed",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({
    open_requests: Schema.Int,
    unread: Schema.Int,
    by_priority: Schema.Record(Schema.String, Schema.Int),
    by_poster_kind: Schema.Record(Schema.String, Schema.Int),
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Badge counts: open requests, unread active items, open requests by priority.",
  cli: { path: "feed counts", visible: true },
  mcp: { expose: "never", group: "feed" }
})

export const FeedKinds = def({
  name: "feed.kinds",
  owner: "cloud:FeedDO",
  class: "read",
  risk: "read",
  target: "feed",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ kinds: Schema.Array(Schema.Struct({ kind: Schema.String, priority: FeedPriority, needs_mac: Schema.Boolean, docs: Schema.String })) }),
  errors: ["auth.unauthenticated"],
  docs: "The built-in request kinds; custom kinds x-<publisher>.<name> carry their own answer_schema.",
  cli: { path: "feed kinds", visible: true },
  mcp: { expose: "default", group: "feed" }
})

export const feedOps = [FeedPost, FeedAnswer, FeedCancel, FeedRead, FeedSeen, FeedArchive, FeedUnarchive, FeedSnooze, FeedPrefsSet, FeedAdopt, FeedList, FeedGet, FeedCounts, FeedKinds] as const

const internal = (name: string, docs: string, params: Schema.Top): CloudOpDef =>
  ({
    name,
    owner: "cloud:FeedDO",
    class: "mutation",
    risk: "mutate-own",
    target: "feed",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** FeedDO's own ops from its alarm; never in the public catalog. */
export const feedInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("feed.expire", "Internal: close items whose expiry is at or before `at`.", Schema.Struct({ at: Schema.Int })),
  internal("feed.snooze_wake", "Internal: bring back items whose snooze ended at or before `at`.", Schema.Struct({ at: Schema.Int })),
  internal("feed.prune", "Internal: drop closed or archived items that ended before `before`.", Schema.Struct({ before: Schema.Int })),
  internal(
    "feed.push_due",
    "Internal: record the push decision for items due at or before `at`.",
    Schema.Struct({ at: Schema.Int, send: Schema.Array(FeedItemId), skip: Schema.Array(FeedItemId) })
  )
]
