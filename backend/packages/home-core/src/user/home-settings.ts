import { ALLOW_REQUESTS_FROM, type AllowRequestsFrom } from "../conversation/reach.ts"

/**
 * Home settings, owned by the user's UserDO (home-messaging.md section 4.2
 * `home.settings.set`). `allow_requests_from` narrows who may reach the user
 * (conversation/reach.ts); the discovery flags are stored for compose
 * (section 16.4) and read by nothing else yet.
 */
export interface HomeSettings {
  readonly discoverable_by_email: boolean
  readonly discoverable_by_phone: boolean
  readonly allow_requests_from: AllowRequestsFrom
  /**
   * R2 (section 16.9): a message request from an unrelated user also sends an email. Stored
   * now; read once message requests (16.4) exist.
   */
  readonly email_requests: boolean
}

/**
 * Values before the first `home.settings.set`. Not discoverable by address
 * (16.4: compose matches only relationships and team co-members), and
 * `anyone`, which allows the base reach rule (a shared team or a connection)
 * without narrowing it.
 */
export const DEFAULT_HOME_SETTINGS: HomeSettings = { discoverable_by_email: false, discoverable_by_phone: false, allow_requests_from: "anyone", email_requests: true }

export type HomeSettingsResult = { readonly ok: true; readonly settings: HomeSettings } | { readonly ok: false; readonly code: "invalid_settings" }

/**
 * Stored settings with defaults for fields added later (a value written before `email_requests`
 * existed). Only known fields are kept: a field from an older shape (`allow_dm_from`, never
 * deployed) is dropped and its replacement reads as the default.
 */
export const homeSettingsOf = (current: Partial<HomeSettings> | undefined): HomeSettings => {
  const pick = <K extends keyof HomeSettings>(key: K, valid: (v: unknown) => boolean): HomeSettings[K] =>
    current !== undefined && valid(current[key]) ? (current[key] as HomeSettings[K]) : DEFAULT_HOME_SETTINGS[key]
  const flag = (v: unknown) => typeof v === "boolean"
  return {
    discoverable_by_email: pick("discoverable_by_email", flag),
    discoverable_by_phone: pick("discoverable_by_phone", flag),
    allow_requests_from: pick("allow_requests_from", (v) => ALLOW_REQUESTS_FROM.includes(v as AllowRequestsFrom)),
    email_requests: pick("email_requests", flag)
  }
}

/** `home.settings.set {discoverable_by_email?, discoverable_by_phone?, allow_requests_from?, email_requests?}`: a partial update; at least one field. */
export const reduceHomeSettings = (current: HomeSettings | undefined, params: unknown): HomeSettingsResult => {
  const base = homeSettingsOf(current)
  if (typeof params !== "object" || params === null) return { ok: false, code: "invalid_settings" }
  const { discoverable_by_email: email, discoverable_by_phone: phone, allow_requests_from: allow, email_requests: requests } = params as Record<string, unknown>
  if (email === undefined && phone === undefined && allow === undefined && requests === undefined) return { ok: false, code: "invalid_settings" }
  if ([email, phone, requests].some((flag) => flag !== undefined && typeof flag !== "boolean")) return { ok: false, code: "invalid_settings" }
  if (allow !== undefined && !ALLOW_REQUESTS_FROM.includes(allow as AllowRequestsFrom)) return { ok: false, code: "invalid_settings" }
  return {
    ok: true,
    settings: {
      discoverable_by_email: (email as boolean | undefined) ?? base.discoverable_by_email,
      discoverable_by_phone: (phone as boolean | undefined) ?? base.discoverable_by_phone,
      allow_requests_from: (allow as AllowRequestsFrom | undefined) ?? base.allow_requests_from,
      email_requests: (requests as boolean | undefined) ?? base.email_requests
    }
  }
}
