import { and, eq, inArray, isNull, sql } from "drizzle-orm"
import type { Env } from "./env.ts"
import { devices, pushTokens, teamPrefs } from "./schema.ts"

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

const NO_PREFS: Prefs = { color: null, emoji: null, transparent: false }

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

const iso = (d: Date | null) => (d ? d.toISOString() : null)
const row = (r: typeof devices.$inferSelect): Device => ({
  deviceId: r.deviceId,
  ownerUserId: r.ownerUserId,
  teamId: r.teamId,
  kind: r.kind,
  name: r.name,
  wgPublicKey: r.wgPublicKey,
  machineId: r.machineId,
  createdAt: r.createdAt.toISOString(),
  updatedAt: r.updatedAt.toISOString(),
  lastSeenAt: iso(r.lastSeenAt)
})

const pushRow = (r: typeof pushTokens.$inferSelect): PushRegistration => ({
  deviceId: r.deviceId,
  ownerUserId: r.ownerUserId,
  token: r.token,
  environment: r.environment,
  topic: r.topic,
  kinds: r.kinds.split(",").filter((k): k is PushKind => (PUSH_KINDS as ReadonlyArray<string>).includes(k)),
  mutedMacs: (r.mutedMacs ?? "").split(",").filter(Boolean),
  previews: r.previews ?? true,
  updatedAt: r.updatedAt.toISOString()
})

/** PlanetScale Postgres through Hyperdrive; one connection per request (Hyperdrive pools). */
export const pgStore = async (hyperdrive: Hyperdrive): Promise<Store> => {
  // Loaded lazily: pg is CommonJS and only the deployed Worker (with Hyperdrive) needs it.
  const [{ default: pg }, { drizzle }] = await Promise.all([import("pg"), import("drizzle-orm/node-postgres")])
  const client = new pg.Client({ connectionString: hyperdrive.connectionString })
  await client.connect()
  const db = drizzle(client)
  return {
    async getDevice(deviceId) {
      const [r] = await db.select().from(devices).where(eq(devices.deviceId, deviceId)).limit(1)
      return r ? row(r) : undefined
    },
    async upsertDevice(d) {
      // Read the previous team for the move; the conditional update (setWhere) still refuses a racing other owner.
      const [prev] = await db.select({ teamId: devices.teamId, owner: devices.ownerUserId }).from(devices).where(eq(devices.deviceId, d.deviceId)).limit(1)
      if (prev && prev.owner !== d.ownerUserId) return "not_owner"
      const machine = d.machineId === undefined ? {} : { machineId: d.machineId }
      const [r] = await db
        .insert(devices)
        .values({ ...d, machineId: d.machineId ?? null })
        .onConflictDoUpdate({
          target: devices.deviceId,
          set: { teamId: d.teamId, kind: d.kind, name: d.name, wgPublicKey: d.wgPublicKey, ...machine, updatedAt: sql`now()` },
          setWhere: eq(devices.ownerUserId, d.ownerUserId)
        })
        .returning()
      if (!r) return "not_owner"
      return { device: row(r), previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
    },
    async claimSiblings(ownerUserId, machineId, deviceIds) {
      if (!deviceIds.length) return []
      await db
        .update(devices)
        .set({ machineId })
        .where(and(eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"), isNull(devices.machineId), inArray(devices.deviceId, [...deviceIds])))
      const rs = await db
        .select({ deviceId: devices.deviceId })
        .from(devices)
        .where(and(eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"), eq(devices.machineId, machineId), inArray(devices.deviceId, [...deviceIds])))
      return rs.map((r) => r.deviceId)
    },
    async listOwnerMacs(ownerUserId) {
      const rs = await db.select().from(devices).where(and(eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"))).orderBy(devices.name)
      return rs.map(row)
    },
    async listOwnerDevices(ownerUserId) {
      const rs = await db
        .select({ d: devices, token: pushTokens.token })
        .from(devices)
        .leftJoin(pushTokens, eq(pushTokens.deviceId, devices.deviceId))
        .where(eq(devices.ownerUserId, ownerUserId))
        .orderBy(devices.kind, devices.name)
      return rs.map((r) => ({ ...row(r.d), push: !!r.token }))
    },
    async deleteDevice(deviceId, ownerUserId) {
      const [prev] = await db.select().from(devices).where(eq(devices.deviceId, deviceId)).limit(1)
      if (!prev) return undefined
      if (prev.ownerUserId !== ownerUserId) return "not_owner"
      await db.delete(pushTokens).where(eq(pushTokens.deviceId, deviceId))
      const [r] = await db.delete(devices).where(and(eq(devices.deviceId, deviceId), eq(devices.ownerUserId, ownerUserId))).returning()
      return r ? row(r) : undefined
    },
    async deleteOwner(ownerUserId) {
      await db.delete(pushTokens).where(eq(pushTokens.ownerUserId, ownerUserId))
      await db.delete(teamPrefs).where(eq(teamPrefs.userId, ownerUserId))
      return (await db.delete(devices).where(eq(devices.ownerUserId, ownerUserId)).returning()).map(row)
    },
    async setPush(p) {
      const kinds = p.kinds.join(",")
      const mutedMacs = p.mutedMacs.length ? p.mutedMacs.join(",") : null
      const [r] = await db
        .insert(pushTokens)
        .values({ ...p, kinds, mutedMacs })
        .onConflictDoUpdate({
          target: pushTokens.deviceId,
          set: { ownerUserId: p.ownerUserId, token: p.token, environment: p.environment, topic: p.topic, kinds, mutedMacs, previews: p.previews, updatedAt: sql`now()` }
        })
        .returning()
      return pushRow(r!)
    },
    async deletePush(deviceId) {
      await db.delete(pushTokens).where(eq(pushTokens.deviceId, deviceId))
    },
    async listOwnerPush(ownerUserId) {
      return (await db.select().from(pushTokens).where(eq(pushTokens.ownerUserId, ownerUserId))).map(pushRow)
    },
    async dropPushTokens(tokens) {
      if (tokens.length) await db.delete(pushTokens).where(inArray(pushTokens.token, [...tokens]))
    },
    async getPrefs(userId, teamId) {
      const [r] = await db.select().from(teamPrefs).where(and(eq(teamPrefs.userId, userId), eq(teamPrefs.teamId, teamId))).limit(1)
      return r ? { color: r.color, emoji: r.emoji, transparent: r.transparent && hasIcon(r.emoji) } : { ...NO_PREFS }
    },
    async putPrefs(userId, teamId, patch) {
      const set: Record<string, unknown> = { updatedAt: sql`now()` }
      if (patch.color !== undefined) set.color = patch.color
      if (patch.emoji !== undefined) set.emoji = patch.emoji
      if (patch.transparent !== undefined) set.transparent = patch.transparent
      const [r] = await db
        .insert(teamPrefs)
        .values({ userId, teamId, color: patch.color ?? null, emoji: patch.emoji ?? null, transparent: patch.transparent ?? false })
        .onConflictDoUpdate({ target: [teamPrefs.userId, teamPrefs.teamId], set })
        .returning()
      return r ? { color: r.color, emoji: r.emoji, transparent: r.transparent && hasIcon(r.emoji) } : { ...NO_PREFS }
    },
    async listTeamScopes() {
      const r = await client.query<{ project: string | null; team_id: string; device_ids: Array<string> | null }>(
        `SELECT project, team_id, array_agg(device_id::text) FILTER (WHERE device_id IS NOT NULL) AS device_ids FROM (
           SELECT NULLIF(split_part(owner_user_id, ':', 1), owner_user_id) AS project, team_id, device_id FROM devices
           UNION ALL SELECT NULLIF(split_part(user_id, ':', 1), user_id) AS project, team_id, NULL FROM team_prefs
         ) t GROUP BY project, team_id`
      )
      return r.rows.map((x) => ({ project: x.project, teamId: x.team_id, deviceIds: x.device_ids ?? [] }))
    },
    close: () => client.end()
  }
}

/** In-memory store for tests (ENVIRONMENT=test, no Hyperdrive binding). Shared per isolate. */
const mem = { devices: new Map<string, Device>(), prefs: new Map<string, Prefs>(), push: new Map<string, PushRegistration>() }
export const memoryStore = (): Store => ({
  async getDevice(id) {
    const d = mem.devices.get(id)
    return d ? { ...d } : undefined
  },
  async upsertDevice(d) {
    const prev = mem.devices.get(d.deviceId)
    if (prev && prev.ownerUserId !== d.ownerUserId) return "not_owner"
    const now = new Date().toISOString()
    const device: Device = {
      ...d,
      machineId: d.machineId === undefined ? (prev?.machineId ?? null) : d.machineId,
      createdAt: prev?.createdAt ?? now,
      updatedAt: now,
      lastSeenAt: prev?.lastSeenAt ?? null
    }
    mem.devices.set(d.deviceId, device)
    return { device: { ...device }, previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
  },
  async claimSiblings(owner, machineId, ids) {
    const claimed: Array<string> = []
    for (const id of ids) {
      const d = mem.devices.get(id)
      if (!d || d.ownerUserId !== owner || d.kind !== "mac" || (d.machineId !== null && d.machineId !== machineId)) continue
      if (d.machineId === null) mem.devices.set(id, { ...d, machineId })
      claimed.push(id)
    }
    return claimed
  },
  async listOwnerMacs(owner) {
    return [...mem.devices.values()].filter((d) => d.ownerUserId === owner && d.kind === "mac").sort((a, b) => a.name.localeCompare(b.name))
  },
  async listOwnerDevices(owner) {
    return [...mem.devices.values()]
      .filter((d) => d.ownerUserId === owner)
      .sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name))
      .map((d) => ({ ...d, push: mem.push.has(d.deviceId) }))
  },
  async deleteDevice(id, owner) {
    const d = mem.devices.get(id)
    if (!d) return undefined
    if (d.ownerUserId !== owner) return "not_owner"
    mem.devices.delete(id)
    mem.push.delete(id)
    return { ...d }
  },
  async deleteOwner(owner) {
    const gone = [...mem.devices.values()].filter((d) => d.ownerUserId === owner)
    for (const d of gone) mem.devices.delete(d.deviceId)
    for (const [k, p] of mem.push) if (p.ownerUserId === owner) mem.push.delete(k)
    for (const k of mem.prefs.keys()) if (k.startsWith(`${owner}\u0000`)) mem.prefs.delete(k)
    return gone
  },
  async setPush(p) {
    const r = { ...p, kinds: [...p.kinds], mutedMacs: [...p.mutedMacs], updatedAt: new Date().toISOString() }
    mem.push.set(p.deviceId, r)
    return { ...r }
  },
  async deletePush(id) {
    mem.push.delete(id)
  },
  async listOwnerPush(owner) {
    return [...mem.push.values()].filter((p) => p.ownerUserId === owner).map((p) => ({ ...p, kinds: [...p.kinds], mutedMacs: [...p.mutedMacs] }))
  },
  async dropPushTokens(tokens) {
    for (const [k, p] of mem.push) if (tokens.includes(p.token)) mem.push.delete(k)
  },
  async getPrefs(u, t) {
    return { ...(mem.prefs.get(`${u}\u0000${t}`) ?? NO_PREFS) }
  },
  async putPrefs(u, t, patch) {
    const k = `${u}\u0000${t}`
    const cur = mem.prefs.get(k) ?? NO_PREFS
    const emoji = patch.emoji !== undefined ? patch.emoji : cur.emoji
    const next: Prefs = {
      color: patch.color !== undefined ? patch.color : cur.color,
      emoji,
      // As Postgres's read: never transparent without an icon.
      transparent: (patch.transparent !== undefined ? patch.transparent : cur.transparent) && hasIcon(emoji)
    }
    mem.prefs.set(k, next)
    return { ...next }
  },
  async listTeamScopes() {
    const scope = (owner: string) => (owner.includes(":") ? owner.slice(0, owner.indexOf(":")) : null)
    const out = new Map<string, { project: string | null; teamId: string; deviceIds: Array<string> }>()
    const add = (project: string | null, teamId: string, deviceId?: string) => {
      const k = `${project}\u0000${teamId}`
      const row = out.get(k) ?? { project, teamId, deviceIds: [] }
      if (deviceId) row.deviceIds.push(deviceId)
      out.set(k, row)
    }
    for (const d of mem.devices.values()) add(scope(d.ownerUserId), d.teamId, d.deviceId)
    for (const k of mem.prefs.keys()) add(scope(k.split("\u0000")[0]!), k.split("\u0000")[1]!)
    return [...out.values()]
  },
  close: async () => {}
})

export const openStore = (env: Env): Promise<Store> => {
  if (env.HYPERDRIVE) return pgStore(env.HYPERDRIVE)
  // Tests, and `wrangler dev` of the local (top-level) config: rows live in the isolate's memory.
  if (env.ENVIRONMENT === "test" || env.ENVIRONMENT === "local") return Promise.resolve(memoryStore())
  throw new Error("no database binding")
}
