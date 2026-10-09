import type { FeedItem } from "@cmux/protocol"
import type { FeedState } from "./feed.ts"

/**
 * Pure decisions behind FeedDO's after-commit notifications
 * (plans/cmux-next/ios-next/c7-notify.md sections 3 and 6).
 */

/** Whether an item still deserves its banner on a phone: an open request or an unread active notice. */
export const needsUser = (i: FeedItem): boolean => (i.type === "request" ? i.state === "open" : i.state === "open" && i.archived_at === null && i.read_at === null)

/** The badge: open requests plus unread active notices (the iPhone's FeedCounts). */
export const feedBadge = (state: FeedState, now: number): number =>
  Object.values(state.items).filter((i) => (i.type === "request" ? i.state === "open" : needsUser(i) && (i.snoozed_until === null || i.snoozed_until <= now))).length

/** Items that were pushed and no longer need the user, not yet dismissed (at most 256 per push). */
export const dismissDue = (state: FeedState, dismissed: ReadonlySet<string>): ReadonlyArray<string> =>
  Object.values(state.items)
    .filter((i) => i.pushed_at !== null && !needsUser(i) && !dismissed.has(i.id))
    .map((i) => i.id)
    .sort()
    .slice(0, 256)

/** Open requests that name a task or terminal: the only items a Live Activity follows. */
export const activityRequests = (state: FeedState): ReadonlyArray<FeedItem> =>
  Object.values(state.items).filter((i) => i.type === "request" && i.state === "open" && (i.context.task !== undefined || i.context.terminal !== undefined))

/** Changes when the set of those requests changes; FeedDO asks UserDO for activities only then. */
export const activitySignature = (state: FeedState): string =>
  activityRequests(state)
    .map((i) => `${i.context.host ?? ""}|${i.context.task ?? ""}|${i.context.terminal ?? ""}|${i.id}`)
    .sort()
    .join("\n")
