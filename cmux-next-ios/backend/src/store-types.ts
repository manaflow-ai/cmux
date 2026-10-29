/** Store contract and the pure helpers shared by every store (memory, Postgres, MySQL). No database imports. */
export type DeviceKind = "mac" | "phone"

export interface Device {
  deviceId: string
  /** The owner key: the bare Stack sub for the primary project, `<projectId>:<sub>` otherwise (src/index.ts ownerKey). */
  ownerUserId: string
  teamId: string
  kind: DeviceKind
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
  ownerUserId: string
  teamId: string
  kind: DeviceKind
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

export interface Store {
  getDevice(deviceId: string): Promise<Device | undefined>
  /** Insert or update; "not_owner" when the id already belongs to another user (nothing changes). */
  upsertDevice(d: DeviceInput): Promise<{ device: Device; previousTeamId: string | null } | "not_owner">
  /**
   * Gives `machineId` to those of `deviceIds` that are Macs of `ownerUserId` with no machine id yet (other builds
   * on the registering Mac, PROTOCOL.md "Devices"). A Mac's own report always wins. Returns every one of
   * `deviceIds` that has this machine id now (claimed now or earlier), so a hub that missed an earlier claim
   * catches up.
   */
  claimSiblings(ownerUserId: string, machineId: string, deviceIds: ReadonlyArray<string>): Promise<Array<string>>
  /** Every Mac one owner registered, in any team or personal space (`ownerUserId` is the owner key). */
  listOwnerMacs(ownerUserId: string): Promise<Array<Device>>
  /** Every device (Mac or phone) of one owner, with whether it has a push token. */
  listOwnerDevices(ownerUserId: string): Promise<Array<Device & { push: boolean }>>
  /** Deletes a device and its push token; "not_owner" when another user owns it (nothing changes). */
  deleteDevice(deviceId: string, ownerUserId: string): Promise<Device | "not_owner" | undefined>
  /** Deletes every device, push token and pref of one owner; returns the deleted devices. */
  deleteOwner(ownerUserId: string): Promise<Array<Device>>
  setPush(p: Omit<PushRegistration, "updatedAt">): Promise<PushRegistration>
  deletePush(deviceId: string): Promise<void>
  /** Push registrations of the owner's phones. */
  listOwnerPush(ownerUserId: string): Promise<Array<PushRegistration>>
  /** Forget tokens APNs reported as gone. */
  dropPushTokens(tokens: ReadonlyArray<string>): Promise<void>
  getPrefs(userId: string, teamId: string): Promise<Prefs>
  /** Only the given fields change; `undefined` keeps the stored value. */
  putPrefs(userId: string, teamId: string, patch: Partial<Prefs>): Promise<Prefs>
  /**
   * Every team id the database knows (devices and team prefs), with the Stack project of its rows: null for the
   * primary project (bare owner keys), else the project id (`<projectId>:<sub>` keys). Names the old team hubs.
   */
  listTeamScopes(): Promise<Array<{ project: string | null; teamId: string; deviceIds: Array<string> }>>
  close(): Promise<void>
}
