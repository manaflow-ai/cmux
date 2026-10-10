# CmuxHomeCore: the Home data path

Every Home front end reads and writes conversations through one API. The
Swift Home (MessagesLab) and the React Home (`HomeChannelsPageProvider`,
cx-59n8) both use it. The API is the `HomeSource` protocol. In the macOS app
the one instance is `HomeService.homeRouter`. This router sends each read and
each op to the owner of its conversation: the local Chief owner (the Chief
home's daemon, `DaemonHomeSource`) or the cloud owner (`CloudHomeSource`).
No front end talks to a daemon or the cloud directly.

Stable contract. Do not rename these names or change their types without
telling hq-6d first. Additions are fine.

## Reads

| Call | Returns |
|---|---|
| `events()` | A new `AsyncStream<HomeEvent>` for each call. Many subscribers are allowed. The first events are `.connection`, then `.inbox`. |
| `inbox()` | An `InboxSnapshot`: `me` and every `ConversationSummary`. |
| `snapshot(of:tail:)` | A `ConversationPage`: the summary and the newest `tail` messages, oldest first. |
| `history(of:before:limit:)` | Up to `limit` messages before `seq`, oldest first. |
| `search(_:limit:)` | Message hits. Only the local owner can search now. |

`ConversationSummary`: `id`, `owner` (`.local` or `.cloud`), `title` (empty
means a title made from the participants), `participants`, `lastSeq`, `rev`,
`updatedAt`, `lastMessage`, `unreadCount(me:)`, `mentionCount`, `muted`,
`pinRank`, `kind(me:)` (`.chief`, `.direct` or `.group`).

`unreadCount(me:)` does not count my own messages. My newest message counts
as read up to its seq. Also, the local owner moves the read cursor of the
sender to the seq of each send, for every client (CLI and paired phones too).
Thus a reply between messages from other people does not count.

`Message`: `id`, `conversation`, `seq`, `author`, `parts`, `createdAt`,
`editedAt`, `retractedAt`, `reactions`, `replyTo`, `threadRoot`.

`Participant`: `id`, `kind`, `displayName`, `isChief`.

## Writes: `submit(HomeIntent(op:))`

Each intent has an idempotency key (`HomeIntent.key`). An owner applies a key
one time only. A resend with the same key gets the stored answer back
(`replayed`). A refusal is `HomeRejection.invalid(reason)`.

| Op | Owner op | Notes |
|---|---|---|
| `.sendMessage(conversation:parts:threadRoot:)` | `message.send` | `threadRoot` is optional. When it is set, the message is a reply in the thread of that root. The local owner stores it as `thread_root` and refuses a root that is itself in a thread (`invalid_thread_root`). Both owners also carry the root as `reply_to` part 0, so an owner without threads (the cloud owner, an older daemon) keeps the thread. A message without `thread_root` reads its thread from `reply_to`. |
| `.editMessage(message:conversation:parts:)` | `message.edit` | Only for my own messages. The owner sets `editedAt`. |
| `.retractMessage(message:conversation:)` | `message.retract` | Only for my own messages. The owner sets `retractedAt`. |
| `.addReaction(message:conversation:reaction:partIndex:)` | `reaction.add` | |
| `.removeReaction(message:conversation:reaction:partIndex:)` | `reaction.remove` | Removes my reaction of the same kind on the same part. |
| `.setReadCursor(conversation:seq:)` | `read_cursor.set` | The cursor only moves forward. |
| `.createGroup(title:participants:)` | `conversation-create` (local) or `conversation.create` (cloud) | Local participants only (none, the Chief `agent_mux`, or people already in local conversations): the local owner makes a local channel with me (and the Chief when the list is empty). It refuses an unknown participant with `unknown_participant`. When the list has a cloud participant, the cloud owner makes the group. |
| `.setTyping(conversation:on:)` | typing frame | Not stored. |
| `.answerQuestion`, `.openDirect`, `.startConversation`, `.invite`, `.setPinned`, `.setMuted`, `.createChief` | | These have not changed. Pin, mute and createChief are refused by both owners now. |

A change that a write commits comes back on `events()` as `.message` (a new
or changed message) or `.conversationChanged`. A new local channel comes
back as a new `.inbox`.

## Two Homes at the same time

The Swift Home and the React Home can be open together. Each one has its own
`events()` subscription on the same `homeRouter`. A write in one Home commits
on the owner, and the owner's event goes to all subscribers. Thus the write
shows in the other Home at once, and no front end must poll or refetch.

## Behavior check

`scripts/cmux-next/home-api-live.py --tag <tag>` (runs on cmux-lawrence-2)
starts the tagged app. It calls the socket command `debug.home.api` (`inbox`,
`snapshot`, `submit`) to run each op above through `homeRouter` against the
real local owner. The calls `watch_start` and `watch_read` open a second
`events()` subscriber, and `store` reads the transcript of the Swift Home
store. With these calls the script makes sure that a write in one Home shows
in the other.

## Known limits

- The cloud owner has no `thread_root` field yet. A cloud thread reply is a
  `reply_to` the root, so the cloud stores a reply to a reply as a thread of
  that reply. The Slack-style composer always sends the root.
- The cloud owner does not move the read cursor of the sender. The
  `unreadCount(me:)` rule above keeps my own cloud messages read.
