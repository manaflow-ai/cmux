import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"

/**
 * Device push targets (identity spec section 2: a device holds its push
 * tokens; owner UserDO). The feed owner reads them to deliver its
 * owner-decided pushes (plans/cmux-next/feed.md 7.3).
 */

export const PushToken = Schema.String.check(Schema.isPattern(/^[a-f0-9]{32,200}$/)).annotate({
  identifier: "PushToken",
  description: "An APNs device token (hex)."
})

export const PushTarget = Schema.Struct({
  token: PushToken,
  /** The app's bundle id, used as the APNs topic. */
  topic: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9.-]{3,200}$/)),
  environment: Schema.Literals(["development", "production"]),
  install: Schema.String,
  device_name: Schema.String.check(Schema.isMaxLength(80)),
  registered_at: Schema.Int
}).annotate({ identifier: "PushTarget", description: "One device's APNs registration." })
export type PushTarget = typeof PushTarget.Type

export const PushTargetRegister = def({
  name: "push.target.register",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "push_target",
  principals: ["install"],
  params: Schema.Struct({
    token: PushToken,
    topic: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9.-]{3,200}$/)),
    environment: Schema.Literals(["development", "production"]),
    device_name: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(80)))
  }),
  result: PushTarget,
  errors: mutationErrors,
  docs: "Register the calling iPhone or iPad install's APNs token (replaces the install's earlier token).",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const PushTargetRemove = def({
  name: "push.target.remove",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "push_target",
  principals: ["session", "install"],
  params: Schema.Struct({ token: PushToken }),
  result: Schema.Struct({ token: PushToken, removed: Schema.Boolean }),
  errors: mutationErrors,
  docs: "Remove an APNs token (sign-out on the device, or the user removes a device).",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const pushOps = [PushTargetRegister, PushTargetRemove] as const

/** UserDO's own op: drop a token APNs reported unregistered or invalid. Never in the public catalog. */
export const pushInternalOps: ReadonlyArray<CloudOpDef> = [
  {
    name: "push.target.drop",
    owner: "cloud:UserDO",
    class: "mutation",
    risk: "mutate-own",
    target: "push_target",
    principals: ["system"],
    params: Schema.Struct({ token: PushToken, reason: Schema.String.check(Schema.isMaxLength(80)) }),
    result: Schema.Unknown,
    errors: [],
    docs: "Internal: drop a push token APNs rejected.",
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  } as CloudOpDef
]
