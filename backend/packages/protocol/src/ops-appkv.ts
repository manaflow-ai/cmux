import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { isMinLength } from "./json-checks.ts"

/**
 * Synced app storage (`storage:synced`, cmuxterm-hq#12221): a per-user key-value store on the
 * UserDO stream `appkv:<user>`. The Mac daemon (later iOS) writes through these ops and mirrors
 * the stream: one row per (app, key), `{app, key, value, revision, updated_ms}`; a delete removes
 * the row. The UserDO orders writes, so the last write to a key wins. Limits as the local
 * `app.storage.*`: key 1 to 256 bytes, value at most 64 KiB as JSON, 4 MiB per app (`app.limit`).
 */
const AppId = Schema.String.check(isMinLength(1), Schema.isMaxLength(128)).annotate({ identifier: "AppKvApp" })
const AppKey = Schema.String.check(isMinLength(1), Schema.isMaxLength(256)).annotate({ identifier: "AppKvKey" })

export const AppKvRow = Schema.Struct({
  app: Schema.String,
  key: Schema.String,
  value: Schema.Unknown,
  revision: Schema.Number,
  updated_ms: Schema.Number
}).annotate({ identifier: "AppKvRow" })

const appkvErrors = [...mutationErrors, "app.limit"]

export const AppKvSet = def({
  name: "appkv.set",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "appkv",
  principals: ["session", "install"],
  params: Schema.Struct({ app: AppId, key: AppKey, value: Schema.Unknown }),
  result: AppKvRow,
  errors: appkvErrors,
  docs: "Set one key of an app's synced storage (storage:synced) to a JSON value (at most 64 KiB; 4 MiB per app). The last write wins.",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const AppKvDelete = def({
  name: "appkv.delete",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "appkv",
  principals: ["session", "install"],
  params: Schema.Struct({ app: AppId, key: AppKey }),
  result: Schema.Struct({ app: Schema.String, key: Schema.String, existed: Schema.Boolean }),
  errors: mutationErrors,
  docs: "Delete one key of an app's synced storage (storage:synced). Deleting a missing key succeeds.",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const AppKvList = def({
  name: "appkv.list",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "appkv",
  principals: ["session", "install"],
  params: Schema.Struct({
    /** Rows with a revision above this one (the previous page's `next_after_revision`); absent = from the start. */
    after_revision: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))),
    limit: Schema.optionalKey(Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1), Schema.isLessThanOrEqualTo(500)))
  }),
  result: Schema.Struct({ rows: Schema.Array(AppKvRow), next_after_revision: Schema.NullOr(Schema.Number), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Page every row of your synced app storage in revision order (a stream snapshot carries only the newest 1000).",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const appKvOps = [AppKvSet, AppKvDelete, AppKvList] as const
