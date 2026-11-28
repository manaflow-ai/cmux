/** Store contract and the pure helpers shared by every store (memory, Postgres, MySQL). No database imports. */
export type DeviceKind = "mac" | "phone"

/** Forward-compatible glyph names, shared with the device hub; malformed strings never erase a known kind. */
export const modelKind = (value: unknown): string | undefined =>
  typeof value === "string" && value.length <= 32 && /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(value) ? value : undefined

export interface Device {
  deviceId: string
  /** The build space it registered in: "" for stable and nightly, `dev:<slug>` for a dev build (src/index.ts spaceOf). */
  space: string
  /** The owner key: the bare Stack sub for the primary project, `<projectId>:<sub>` otherwise (src/index.ts ownerKey). */
  ownerUserId: string
  teamId: string
  kind: DeviceKind
  /** Hardware model for glyphs, separate from the platform used for admission. */
  modelKind: string | null
  name: string
  wgPublicKey: string | null
  /** A Mac's machine id; null when it sent none (phones, older hosts). */
  machineId: string | null
  createdAt: string
  updatedAt: string
  lastSeenAt: string | null
}

export interface DeviceInput {
  deviceId: string
  space: string
  ownerUserId: string
  teamId: string
  kind: DeviceKind
  /** Undefined preserves the stored model kind, including registrations from older clients. */
  modelKind?: string
  name: string
  wgPublicKey: string | null
  /** Undefined keeps the stored machine id (a host that predates it, or a phone). */
  machineId?: string
}

export interface Prefs {
  color: string | null
  emoji: string | null
  /** Draw the icon with no background. Only with an icon (a non-empty `emoji`); `color` stays the fallback. */
  transparent: boolean
}

/** Prefs of a team the user never styled. */
export const NO_PREFS: Prefs = { color: null, emoji: null, transparent: false }

/** True when `emoji` is an icon the user picked (not automatic `null` or none `""`). */
export const hasIcon = (emoji: string | null): boolean => typeof emoji === "string" && emoji.length > 0

/**
 * The prefs after a PUT. A PUT that sets `color` without `transparent` (every build that predates it) picks a
 * filled badge. A team without an icon is never transparent, so it always keeps a color.
 */
export function mergePrefs(cur: Prefs, patch: Partial<Prefs>): Prefs {
  const color = patch.color !== undefined ? patch.color : cur.color
  const emoji = patch.emoji !== undefined ? patch.emoji : cur.emoji
  const transparent = patch.transparent ?? (patch.color !== undefined ? false : cur.transparent)
  return { color, emoji, transparent: transparent && hasIcon(emoji) }
}

export type PushEnvironment = "sandbox" | "production"
export const PUSH_KINDS = ["question", "permission", "completed", "failed", "chief", "terminal"] as const
export type PushKind = (typeof PUSH_KINDS)[number]

export interface PushRegistration {
  deviceId: string
  /** The phone's build space (as its device row). */
  space: string
  ownerUserId: string
  token: string
  environment: PushEnvironment
  topic: string
  kinds: Array<PushKind>
  /** Mac device ids this phone wants no push from. */
  mutedMacs: Array<string>
  /** Show previews: false hides content in the banner. */
  previews: boolean
  updatedAt: string
}

/**
 * Every read and write names the caller's build space (PROTOCOL.md "Build spaces"): a row of another space is
 * never found, listed, changed or deleted. Device ids stay unique across spaces. The one exception is
 * `upsertDevice` of an id its owner holds in another space: a device id is one install of one build, so the row
 * (and its push token) moves to the registering space. That is how a dev build registered before build spaces
 * (its row in stable) or one whose dev tag changed keeps working. Another owner's id is refused ("other_space").
 */
export interface Store {
  getDevice(space: string, deviceId: string): Promise<Device | undefined>
  /**
   * Insert or update. An id the same owner holds in another space moves here with its push token; `movedFrom`
   * names that space (null otherwise) so its hub can let the device go. Another owner's id is "not_owner" in this
   * space and "other_space" in another (nothing changes).
   */
  upsertDevice(d: DeviceInput): Promise<{ device: Device; previousTeamId: string | null; movedFrom: string | null } | "not_owner" | "other_space">
  /**
   * Gives `machineId` to those of `deviceIds` that are Macs of `ownerUserId` in `space` with no machine id yet
   * (other builds on the registering Mac, PROTOCOL.md "Devices"). A Mac's own report always wins. Returns every
   * one of `deviceIds` that has this machine id now (claimed now or earlier), so a hub that missed an earlier
   * claim catches up.
   */
  claimSiblings(space: string, ownerUserId: string, machineId: string, deviceIds: ReadonlyArray<string>): Promise<Array<string>>
  /** Every Mac one owner registered in `space`, in any team or personal space (`ownerUserId` is the owner key). */
  listOwnerMacs(space: string, ownerUserId: string): Promise<Array<Device>>
  /** Every device (Mac or phone) of one owner in `space`, with whether it has a push token. */
  listOwnerDevices(space: string, ownerUserId: string): Promise<Array<Device & { push: boolean }>>
  /** Deletes a device of `space` and its push token; "not_owner" when another user owns it (nothing changes). */
  deleteDevice(space: string, deviceId: string, ownerUserId: string): Promise<Device | "not_owner" | undefined>
  /**
   * Deletes every device, push token and pref of one owner in one build space, or in every space ("all", the
   * stable app's account deletion); returns the deleted devices.
   */
  deleteOwner(ownerUserId: string, scope: { space: string } | "all"): Promise<Array<Device>>
  setPush(p: Omit<PushRegistration, "updatedAt">): Promise<PushRegistration>
  deletePush(space: string, deviceId: string): Promise<void>
  /** Push registrations of the owner's phones in `space`. */
  listOwnerPush(space: string, ownerUserId: string): Promise<Array<PushRegistration>>
  /** Forget tokens of `space` that APNs reported as gone. */
  dropPushTokens(space: string, tokens: ReadonlyArray<string>): Promise<void>
  getPrefs(space: string, userId: string, teamId: string): Promise<Prefs>
  /** Only the given fields change; `undefined` keeps the stored value. */
  putPrefs(space: string, userId: string, teamId: string, patch: Partial<Prefs>): Promise<Prefs>
  /**
   * Every team id the database knows in the stable space (devices and team prefs), with the Stack project of
   * its rows: null for the primary project (bare owner keys), else the project id (`<projectId>:<sub>` keys).
   * Names the old team hubs, which only stable builds ever used.
   */
  listTeamScopes(): Promise<Array<{ project: string | null; teamId: string; deviceIds: Array<string> }>>
  close(): Promise<void>
}

/**
 * The `user_id` of a team prefs row. The table's primary key is (user_id, team_id), so a dev space's row keeps
 * its own key with the space in front (`dev:<slug>|<owner key>`, as the hub names do); stable rows keep the bare
 * owner key. Making `space` part of the primary key instead is a contract change (drizzle-mysql
 * 0004_mobile_build_space.sql explains it).
 */
export const prefsUserKey = (space: string, userId: string) => (space ? `${space}|${userId}` : userId)
