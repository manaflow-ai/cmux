import { and, eq, inArray, isNull, sql } from "drizzle-orm"
import type { Env } from "./env.ts"
import { devices, pushTokens, teamPrefs } from "./schema.ts"
import { hasIcon, NO_PREFS, PUSH_KINDS, type Device, type PushKind, type Prefs, type PushRegistration, type Store } from "./store-types.ts"

export * from "./store-types.ts"

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

/** PlanetScale MySQL cmux-next-vitess through Hyperdrive (tables `mobile_*`); one connection per request. */
export const vitessStore = async (hyperdrive: Hyperdrive): Promise<Store> => {
  // Loaded lazily, like pg: only the deployed Worker needs the driver.
  const [{ createConnection }, { mysqlStore }] = await Promise.all([import("mysql2/promise"), import("./store-mysql.ts")])
  const conn = await createConnection({
    host: hyperdrive.host,
    port: hyperdrive.port,
    user: hyperdrive.user,
    password: hyperdrive.password,
    database: hyperdrive.database,
    // Workers forbid eval; Hyperdrive terminates TLS to PlanetScale itself.
    disableEval: true,
    timezone: "Z",
    dateStrings: true,
    connectTimeout: 10_000
  })
  return mysqlStore(conn)
}

export const openStore = (env: Env): Promise<Store> => {
  // cmux-next-vitess (vitess-migration-DESIGN.md 2.3). pgStore stays only for a read of the old Postgres.
  if (env.PS_MYSQL) return vitessStore(env.PS_MYSQL)
  // Tests, and `wrangler dev` of the local (top-level) config: rows live in the isolate's memory.
  if (env.ENVIRONMENT === "test" || env.ENVIRONMENT === "local") return Promise.resolve(memoryStore())
  throw new Error("no database binding")
}
