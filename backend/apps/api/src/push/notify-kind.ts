import type { FeedItem, NotificationKind, PushPrefs } from "@cmux/protocol"

/**
 * How a feed item is presented on an iPhone (plans/cmux-next/ios-next/c7-notify.md
 * sections 2 and 4). The Swift side (CmuxFeedPushCore NotificationKind and
 * FeedPushCategory) keeps the same tables; the push carries `notify_kind` so the
 * Notification Service extension never has to guess.
 */

const prompt = (i: FeedItem) => (i.prompt && typeof i.prompt === "object" ? (i.prompt as Record<string, unknown>) : {})

/** The approve scopes the prompt offers. */
export const promptScopes = (i: FeedItem): ReadonlyArray<string> => {
  const scopes = prompt(i).scopes
  return Array.isArray(scopes) ? scopes.filter((s): s is string => typeof s === "string").slice(0, 3) : []
}

/** A review's subject (`plan`, `diff`, ...). */
export const promptSubject = (i: FeedItem): string | undefined => {
  const subject = prompt(i).subject
  return typeof subject === "string" ? subject.slice(0, 20) : undefined
}

export const notificationKindOf = (i: FeedItem): NotificationKind | null => {
  if (i.type === "notice") return i.poster.kind === "system" && i.context.terminal !== undefined ? "terminalAlert" : "finished"
  switch (i.kind) {
    case "approve":
      return "permission"
    case "question":
    case "choice":
    case "confirm":
    case "input":
    case "file":
      return "question"
    case "review":
      return "planApproval"
    default:
      return null
  }
}

/** `aps.category`: answer actions per kind; approve with a session scope and plan reviews get their own. */
export const feedCategory = (i: FeedItem): string => {
  if (i.type !== "request") return "FEED_NOTICE"
  if (i.kind === "approve" && promptScopes(i).includes("session")) return "FEED_APPROVE_SESSION"
  if (i.kind === "review" && promptSubject(i) === "plan") return "FEED_PLAN"
  return `FEED_${i.kind.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`
}

/** Whether this device wants the item at all (no prefs: every kind). */
export const wantsItem = (prefs: PushPrefs | undefined, i: FeedItem): boolean => {
  const kind = notificationKindOf(i)
  return !prefs || kind === null || prefs.kinds.includes(kind)
}

const REQUEST_KINDS: ReadonlySet<NotificationKind> = new Set(["permission", "question", "planApproval"])

/** Urgent items always break through Focus; requests do when the device allows it (default on). */
export const interruptionLevel = (prefs: PushPrefs | undefined, i: FeedItem): "time-sensitive" | undefined => {
  if (i.priority === "urgent") return "time-sensitive"
  const kind = notificationKindOf(i)
  return kind !== null && REQUEST_KINDS.has(kind) && prefs?.time_sensitive !== false ? "time-sensitive" : undefined
}
