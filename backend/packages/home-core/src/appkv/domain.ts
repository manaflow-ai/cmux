import { createHash } from "node:crypto"
import { canonicalJson } from "@cmux/ownership"
import type { Domain, Principal, Reject, ReduceResult, RowWrite } from "../conversation/engine-types.ts"
import { rowsOf } from "../conversation/engine-types.ts"

/**
 * Synced app storage (`storage:synced`, cmuxterm-hq#12221): a per-user key-value store on the
 * UserDO stream `appkv:<user>`. One row per (app, key) in table `item`; the head holds the
 * running revision and each app's usage. The DO orders writes, so the last write to a key wins.
 * The limits match the device's local `app.storage.*` (cmux-tui-core apps/storage.rs): a key is
 * 1 to 256 bytes, a value at most 64 KiB as JSON, an app at most 4 MiB of key and value bytes.
 * Pure: the host passes the caller check (`gate`), so the domain never reads the user's installs.
 */
export const TABLE_ITEM = "item"
export const APPKV_MAX_APP_ID_BYTES = 128
export const APPKV_MAX_KEY_BYTES = 256
export const APPKV_MAX_VALUE_BYTES = 64 * 1024
export const APPKV_MAX_APP_BYTES = 4 * 1024 * 1024
/** Apps one person may keep synced data for (bounds the head). */
export const APPKV_MAX_APPS = 256
/** Rows a snapshot carries (the newest by revision); `appkv.list` pages the rest. */
export const APPKV_SNAPSHOT_ROWS = 1000
export const APPKV_PAGE_LIMIT = 500

export interface AppKvRow {
  readonly app: string
  readonly key: string
  readonly value: unknown
  /** The head revision this write made; also the row's order (`n`). */
  readonly revision: number
  readonly updated_ms: number
}

export interface AppKvUsage {
  /** Key and serialized value bytes (UTF-8), as the local store counts them. */
  readonly bytes: number
  readonly keys: number
}

export interface AppKvHead {
  /** Counts every write and delete that changed a row. */
  readonly revision: number
  readonly apps: Readonly<Record<string, AppKvUsage>>
}

export const INITIAL_APPKV_HEAD: AppKvHead = { revision: 0, apps: {} }

export const APPKV_OPS: ReadonlySet<string> = new Set(["appkv.set", "appkv.delete"])

const encoder = new TextEncoder()
export const utf8Bytes = (s: string): number => encoder.encode(s).length

/**
 * The row key of (app, key): base64url(sha256(app NUL key)), 43 characters, so a 256-byte key
 * fits the engine's 256-character row key. Clients read `app` and `key` from the row itself.
 */
export const appKvRowKey = (app: string, key: string): string => createHash("sha256").update(app).update("\u0000").update(key).digest("base64url")

// eslint-disable-next-line no-control-regex
const CONTROL = /\p{Cc}/u
// UTF-8 replaces unpaired surrogates, which would alias a distinct replacement-character key.
const wellFormed = (value: string): boolean => !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)
const validApp = (app: unknown): app is string => typeof app === "string" && app.length > 0 && wellFormed(app) && utf8Bytes(app) <= APPKV_MAX_APP_ID_BYTES && !CONTROL.test(app)
const validKey = (key: unknown): key is string => typeof key === "string" && key.length > 0 && wellFormed(key) && utf8Bytes(key) <= APPKV_MAX_KEY_BYTES

const refuse = (code: string, message: string): ReduceResult<AppKvHead> => ({ ok: false, code, message })

/** The value as stored: its JSON text, or undefined when it is not JSON (a function, a cycle, undefined). */
const serialized = (value: unknown): string | undefined => {
  try {
    return JSON.stringify(value)
  } catch {
    return undefined
  }
}

/**
 * `app`'s usage, read as an own property only: an app id is any string, so `__proto__`,
 * `toString` or `constructor` must not resolve to Object.prototype's members (which would make
 * the usage NaN and skip the per-app and app-count limits).
 */
const usageOf = (head: AppKvHead, app: string): AppKvUsage | undefined => (Object.hasOwn(head.apps, app) ? head.apps[app] : undefined)

const withUsage = (head: AppKvHead, app: string, usage: AppKvUsage): AppKvHead => {
  const apps: Record<string, AppKvUsage> = { ...head.apps }
  if (usage.keys === 0) delete apps[app]
  // Defined, not assigned: `apps["__proto__"] = usage` would set the prototype, not an entry.
  else Object.defineProperty(apps, app, { value: usage, enumerable: true, writable: true, configurable: true })
  return { revision: head.revision + 1, apps }
}

/**
 * The appkv domain. `gate` is the host's caller check (UserDO: this person, an active install
 * whose grant covers the op, no chief token, no machine install); it runs before the reducer on
 * both the socket and `POST /v1/ops`.
 */
export const makeAppKvDomain = (gate: (principal: Principal, op: string) => Reject | undefined): Domain<AppKvHead, Readonly<Record<string, unknown>>> => ({
  initial: () => INITIAL_APPKV_HEAD,
  authorize: (_head, op, _params, principal) => {
    if (!APPKV_OPS.has(op)) return { code: "validation.invalid", message: `unknown op ${op}` }
    if (principal.kind !== "session" && principal.kind !== "install") return { code: "auth.forbidden", message: `${op} needs the person's session or install` }
    return gate(principal, op)
  },
  reduce: (head, op, params, ctx) => {
    const p = (typeof params === "object" && params !== null ? params : {}) as Record<string, unknown>
    if (!validApp(p.app)) return refuse("validation.invalid", `app must be 1 to ${APPKV_MAX_APP_ID_BYTES} bytes without control characters`)
    if (!validKey(p.key)) return refuse("validation.invalid", `key must be 1 to ${APPKV_MAX_KEY_BYTES} bytes`)
    const { app, key } = p
    const rowKey = appKvRowKey(app, key)
    const current = rowsOf(ctx).get<AppKvRow>(TABLE_ITEM, rowKey)?.row
    const usage = usageOf(head, app) ?? { bytes: 0, keys: 0 }
    const before = current ? utf8Bytes(key) + utf8Bytes(serialized(current.value) ?? "null") : 0

    if (op === "appkv.delete") {
      if (!current) return { ok: true, state: head, value: { app, key, existed: false }, changed: false }
      const state = withUsage(head, app, { bytes: Math.max(0, usage.bytes - before), keys: Math.max(0, usage.keys - 1) })
      const writes: Array<RowWrite> = [{ table: TABLE_ITEM, op: "delete", key: rowKey }]
      return { ok: true, state, value: { app, key, existed: true }, writes }
    }

    if (!("value" in p)) return refuse("validation.invalid", "value is required (JSON)")
    const text = serialized(p.value)
    if (text === undefined) return refuse("validation.invalid", "value must be JSON")
    if (utf8Bytes(text) > APPKV_MAX_VALUE_BYTES) return refuse("app.limit", "value is larger than 64 KiB")
    // Stored as parsed JSON, so the row holds exactly what the text says (no undefined fields).
    const value = JSON.parse(text) as unknown
    if (current && canonicalJson(current.value) === canonicalJson(value)) return { ok: true, state: head, value: current, changed: false }
    if (!current && usageOf(head, app) === undefined && Object.keys(head.apps).length >= APPKV_MAX_APPS) return refuse("app.limit", `synced storage holds at most ${APPKV_MAX_APPS} apps`)
    const after = utf8Bytes(key) + utf8Bytes(text)
    const bytes = usage.bytes - before + after
    if (bytes > APPKV_MAX_APP_BYTES) return refuse("app.limit", "the app's synced storage is full (4 MiB)")
    const state = withUsage(head, app, { bytes, keys: usage.keys + (current ? 0 : 1) })
    const row: AppKvRow = { app, key, value, revision: state.revision, updated_ms: ctx.now }
    return { ok: true, state, value: row, writes: [{ table: TABLE_ITEM, op: "upsert", key: rowKey, n: state.revision, row }] }
  }
})

export interface AppKvPage {
  readonly revision: string
  readonly rows: ReadonlyArray<AppKvRow>
  /** Pass as `after_revision` for the next page; null when this page is the last. */
  readonly next_after_revision: number | null
}
