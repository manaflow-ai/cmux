import { ALLOW_DM_FROM, type AllowDmFrom } from "../conversation/reach.ts"

/**
 * Home settings, owned by the user's UserDO (home-messaging.md section 4.2
 * `home.settings.set`). `allow_dm_from` narrows who may reach the user
 * (conversation/reach.ts); the discovery flags are stored for compose
 * (section 16.4) and read by nothing else yet.
 */
export interface HomeSettings {
  readonly discoverable_by_email: boolean
  readonly discoverable_by_phone: boolean
  readonly allow_dm_from: AllowDmFrom
}

/**
 * Values before the first `home.settings.set`. Not discoverable by address
 * (16.4: compose matches only relationships and team co-members), and
 * `anyone`, which allows the base reach rule (a shared team or a connection)
 * without narrowing it.
 */
export const DEFAULT_HOME_SETTINGS: HomeSettings = { discoverable_by_email: false, discoverable_by_phone: false, allow_dm_from: "anyone" }

export type HomeSettingsResult = { readonly ok: true; readonly settings: HomeSettings } | { readonly ok: false; readonly code: "invalid_settings" }

/** `home.settings.set {discoverable_by_email?, discoverable_by_phone?, allow_dm_from?}`: a partial update; at least one field. */
export const reduceHomeSettings = (current: HomeSettings | undefined, params: unknown): HomeSettingsResult => {
  const base = current ?? DEFAULT_HOME_SETTINGS
  if (typeof params !== "object" || params === null) return { ok: false, code: "invalid_settings" }
  const { discoverable_by_email: email, discoverable_by_phone: phone, allow_dm_from: allow } = params as Record<string, unknown>
  if (email === undefined && phone === undefined && allow === undefined) return { ok: false, code: "invalid_settings" }
  if ((email !== undefined && typeof email !== "boolean") || (phone !== undefined && typeof phone !== "boolean")) return { ok: false, code: "invalid_settings" }
  if (allow !== undefined && !ALLOW_DM_FROM.includes(allow as AllowDmFrom)) return { ok: false, code: "invalid_settings" }
  return {
    ok: true,
    settings: {
      discoverable_by_email: (email as boolean | undefined) ?? base.discoverable_by_email,
      discoverable_by_phone: (phone as boolean | undefined) ?? base.discoverable_by_phone,
      allow_dm_from: (allow as AllowDmFrom | undefined) ?? base.allow_dm_from
    }
  }
}
