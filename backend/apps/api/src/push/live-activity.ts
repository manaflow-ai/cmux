import type { FeedItem } from "@cmux/protocol"
import type { NotifyActivityTarget } from "../domains/user-notify.ts"
import { cut } from "./apns.ts"

/**
 * Live Activity updates (plans/cmux-next/ios-next/c7-notify.md section 6): an
 * activity whose subject matches an open request's context shows needs-input;
 * otherwise running. The content state is CmuxFeedPushCore's
 * AgentActivityState JSON (ActivityKit decodes it with default keys).
 */

export interface ActivityContentState {
  readonly phase: "running" | "needs_input"
  readonly title: string
  readonly started: number
  readonly item?: string
}

/** Same host when both name one, and the same task or terminal. */
export const matchesSubject = (a: NotifyActivityTarget, i: FeedItem): boolean => {
  const s = a.subject
  if (i.context.host !== undefined && i.context.host !== s.host) return false
  return (s.task !== undefined && i.context.task === s.task) || (s.terminal !== undefined && i.context.terminal === s.terminal)
}

/** The state for one activity: the oldest matching open request, else running. */
export const activityState = (a: NotifyActivityTarget, open: ReadonlyArray<FeedItem>): ActivityContentState => {
  const waiting = open.filter((i) => matchesSubject(a, i)).sort((x, y) => x.created_at - y.created_at)[0]
  const started = Math.floor(a.started_at / 1000)
  return waiting ? { phase: "needs_input", title: cut(waiting.title, 80), started, item: waiting.id } : { phase: "running", title: a.title, started }
}

/** A stable key for "what the activity shows", so one state is sent once. */
export const stateKey = (s: ActivityContentState) => `${s.phase}|${s.item ?? ""}`

export const liveActivityRequest = (a: NotifyActivityTarget, state: ActivityContentState, token: string, now: number): Request => {
  const host = a.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
  const alert = state.phase === "needs_input" ? { alert: { title: cut(a.title || state.title, 80), body: state.title } } : {}
  return new Request(`https://${host}/3/device/${a.push_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": `${a.topic}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": state.phase === "needs_input" ? "10" : "5",
      "apns-expiration": String(Math.floor(now / 1000) + 3600),
      "content-type": "application/json"
    },
    body: JSON.stringify({ aps: { timestamp: Math.floor(now / 1000), event: "update", "content-state": state, ...alert } })
  })
}
