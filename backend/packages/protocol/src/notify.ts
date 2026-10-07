import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { PushToken } from "./push.ts"

/**
 * The notify family (plans/cmux-next/ios-next/a0-rpc.md 5.8, c7-notify.md):
 * a device's push preferences and its Live Activity push tokens, owned by
 * UserDO next to the device's push targets. FeedDO reads them to filter,
 * shape and update what it pushes.
 */

/** What a push is about, as the iPhone's notification preferences group them (CmuxFeedPushCore NotificationKind). */
export const NotificationKinds = ["permission", "question", "planApproval", "finished", "terminalAlert"] as const
export type NotificationKind = (typeof NotificationKinds)[number]

export const PushPrefs = Schema.Struct({
  /** Kinds this device wants; a kind left out is not pushed to it. */
  kinds: Schema.Array(Schema.Literals(NotificationKinds)).check(Schema.isMaxLength(NotificationKinds.length)),
  sound: Schema.Boolean,
  /** Requests may break through Focus (`interruption-level: time-sensitive`). */
  time_sensitive: Schema.Boolean
}).annotate({ identifier: "PushPrefs", description: "One device's push preferences." })
export type PushPrefs = typeof PushPrefs.Type

export const PushPrefsSet = def({
  name: "push.prefs.set",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "push_target",
  principals: ["install"],
  params: PushPrefs,
  result: PushPrefs,
  errors: mutationErrors,
  docs: "Set the calling iPhone or iPad install's push preferences (kinds, sound, time-sensitive); the feed owner filters by them.",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const ActivityId = Schema.String.check(Schema.isPattern(/^act_[A-Za-z0-9]{2,64}$/)).annotate({
  identifier: "ActivityId",
  description: "A Live Activity, named by the device that started it."
})

const Id = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128))

export const ActivitySubject = Schema.Struct({
  host: Id,
  task: Schema.optionalKey(Id),
  terminal: Schema.optionalKey(Id)
}).annotate({ identifier: "ActivitySubject", description: "What a Live Activity follows: a task or a terminal on one host." })

export const ActivityTarget = Schema.Struct({
  activity: ActivityId,
  install: Schema.String,
  push_token: PushToken,
  subject: ActivitySubject,
  title: Schema.String.check(Schema.isMaxLength(80)),
  started_at: Schema.Int,
  registered_at: Schema.Int
}).annotate({ identifier: "ActivityTarget", description: "One Live Activity's push-to-update registration." })
export type ActivityTarget = typeof ActivityTarget.Type

export const NotifyActivityRegister = def({
  name: "notify.activity.register",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "push_target",
  principals: ["install"],
  params: Schema.Struct({
    activity: ActivityId,
    push_token: PushToken,
    subject: ActivitySubject,
    title: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(80))),
    started_at: Schema.optionalKey(Schema.Int)
  }),
  result: ActivityTarget,
  errors: mutationErrors,
  docs: "Register a Live Activity's push token (a new token for the same activity replaces the old one).",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const NotifyActivityEnd = def({
  name: "notify.activity.end",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "push_target",
  principals: ["session", "install"],
  params: Schema.Struct({ activity: ActivityId }),
  result: Schema.Struct({ activity: ActivityId, ended: Schema.Boolean }),
  errors: mutationErrors,
  docs: "The Live Activity ended on the device: stop updating it.",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const notifyOps = [PushPrefsSet, NotifyActivityRegister, NotifyActivityEnd] as const
