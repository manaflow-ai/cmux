import type { Env } from "./env.ts"

/**
 * Remote config for the iOS app (lane C16 remote flags; b1-control-do.md section 7). The Worker var
 * `MOBILE_REMOTE_CONFIG` (JSON `{version, flags, min_app_version?}`) overrides the defaults here;
 * a malformed var is ignored (logged once per isolate) so a bad deploy never breaks the app.
 */

export type FlagValue = boolean | number | string

export interface MobileConfig {
  readonly version: number
  readonly flags: Readonly<Record<string, FlagValue>>
  readonly min_app_version?: string
}

/** Defaults every deployment serves; the var only overrides or adds. */
export const DEFAULT_MOBILE_CONFIG: MobileConfig = {
  version: 1,
  flags: {
    "transport.webrtc": true,
    "transport.webrtc_wg": false,
    "transport.direct": true,
    "control.host_socket": true
  }
}

const FLAG_NAME = /^[a-z][a-z0-9_.-]{0,63}$/
let warned = false

/** Defaults merged with the var. Unknown value types and bad names are dropped. */
export const mobileConfig = (env: Pick<Env, "MOBILE_REMOTE_CONFIG">): MobileConfig => {
  if (!env.MOBILE_REMOTE_CONFIG) return DEFAULT_MOBILE_CONFIG
  let raw: { version?: unknown; flags?: unknown; min_app_version?: unknown }
  try {
    raw = JSON.parse(env.MOBILE_REMOTE_CONFIG) as typeof raw
    if (typeof raw !== "object" || raw === null) throw new Error("not an object")
  } catch {
    if (!warned) console.warn(JSON.stringify({ msg: "MOBILE_REMOTE_CONFIG is not valid JSON; serving defaults" }))
    warned = true
    return DEFAULT_MOBILE_CONFIG
  }
  const flags: Record<string, FlagValue> = { ...DEFAULT_MOBILE_CONFIG.flags }
  if (typeof raw.flags === "object" && raw.flags !== null && !Array.isArray(raw.flags)) {
    for (const [k, v] of Object.entries(raw.flags as Record<string, unknown>)) {
      if (!FLAG_NAME.test(k)) continue
      if (typeof v === "boolean" || (typeof v === "number" && Number.isFinite(v)) || (typeof v === "string" && v.length <= 256)) flags[k] = v
    }
  }
  const version = Number.isInteger(raw.version) && (raw.version as number) > 0 ? (raw.version as number) : DEFAULT_MOBILE_CONFIG.version
  const min = typeof raw.min_app_version === "string" && /^[0-9]+(\.[0-9]+){0,3}$/.test(raw.min_app_version) ? raw.min_app_version : undefined
  return { version, flags, ...(min ? { min_app_version: min } : {}) }
}
