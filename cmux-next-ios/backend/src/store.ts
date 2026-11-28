import { and, eq, inArray, isNull, sql } from "drizzle-orm"
import type { Env } from "./env.ts"
import { devices, pushTokens, teamPrefs } from "./schema.ts"
import { hasIcon, NO_PREFS, prefsUserKey, PUSH_KINDS, type Device, type PushKind, type Prefs, type PushRegistration, type Store } from "./store-types.ts"

export * from "./store-types.ts"

const iso = (d: Date | null) => (d ? d.toISOString() : null)
const row = (r: typeof devices.$inferSelect): Device => ({
  deviceId: r.deviceId,
  space: r.space,
  ownerUserId: r.ownerUserId,
  teamId: r.teamId,
  kind: r.kind,
  name: r.name,
  wgPublicKey: r.wgPublicKey,
  machineId: r.machineId,
  modelKind: r.modelKind,
  createdAt: r.createdAt.toISOString(),
  updatedAt: r.updatedAt.toISOString(),
  lastSeenAt: iso(r.lastSeenAt)
})

const pushRow = (r: typeof pushTokens.$inferSelect): PushRegistration => ({
  deviceId: r.deviceId,
  space: r.space,
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
  const inSpace = (space: string) => eq(devices.space, space)
  return {
    async getDevice(space, deviceId) {
      const [r] = await db.select().from(devices).where(and(eq(devices.deviceId, deviceId), inSpace(space))).limit(1)
      return r ? row(r) : undefined
    },
    async upsertDevice(d) {
      // Read the previous team for the move; the conditional update (setWhere) still refuses a racing other owner or space.
      const [prev] = await db.select({ teamId: devices.teamId, owner: devices.ownerUserId, space: devices.space }).from(devices).where(eq(devices.deviceId, d.deviceId)).limit(1)
      if (prev && prev.owner !== d.ownerUserId) return prev.space !== d.space ? "other_space" : "not_owner"
      // The same owner's id in another space moves here, push token first (a retry after a failure moves the rest).
      const movedFrom = prev && prev.space !== d.space ? prev.space : null
      if (movedFrom !== null) {
        await db.update(pushTokens).set({ space: d.space }).where(and(eq(pushTokens.deviceId, d.deviceId), eq(pushTokens.space, movedFrom)))
        await db.update(devices).set({ space: d.space }).where(and(eq(devices.deviceId, d.deviceId), eq(devices.ownerUserId, d.ownerUserId), inSpace(movedFrom)))
      }
      const machine = d.machineId === undefined ? {} : { machineId: d.machineId }
      const model = d.modelKind === undefined ? {} : { modelKind: d.modelKind }
      const [r] = await db
        .insert(devices)
        .values({ ...d, machineId: d.machineId ?? null, modelKind: d.modelKind ?? null })
        .onConflictDoUpdate({
          target: devices.deviceId,
          set: { teamId: d.teamId, kind: d.kind, name: d.name, wgPublicKey: d.wgPublicKey, ...machine, ...model, updatedAt: sql`now()` },
          setWhere: and(eq(devices.ownerUserId, d.ownerUserId), inSpace(d.space))
        })
        .returning()
      if (!r) return "not_owner"
      return { device: row(r), previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null, movedFrom }
    },
    async claimSiblings(space, ownerUserId, machineId, deviceIds) {
      if (!deviceIds.length) return []
      const mine = and(inSpace(space), eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"), inArray(devices.deviceId, [...deviceIds]))
      await db.update(devices).set({ machineId }).where(and(mine, isNull(devices.machineId)))
      const rs = await db.select({ deviceId: devices.deviceId }).from(devices).where(and(mine, eq(devices.machineId, machineId)))
      return rs.map((r) => r.deviceId)
    },
    async listOwnerMacs(space, ownerUserId) {
      const rs = await db.select().from(devices).where(and(inSpace(space), eq(devices.ownerUserId, ownerUserId), eq(devices.kind, "mac"))).orderBy(devices.name)
      return rs.map(row)
    },
    async listOwnerDevices(space, ownerUserId) {
      const rs = await db
        .select({ d: devices, token: pushTokens.token })
        .from(devices)
        .leftJoin(pushTokens, and(eq(pushTokens.deviceId, devices.deviceId), eq(pushTokens.space, devices.space)))
        .where(and(inSpace(space), eq(devices.ownerUserId, ownerUserId)))
        .orderBy(devices.kind, devices.name)
      return rs.map((r) => ({ ...row(r.d), push: !!r.token }))
    },
    async deleteDevice(space, deviceId, ownerUserId) {
      const [prev] = await db.select().from(devices).where(and(eq(devices.deviceId, deviceId), inSpace(space))).limit(1)
      if (!prev) return undefined
      if (prev.ownerUserId !== ownerUserId) return "not_owner"
      await db.delete(pushTokens).where(and(eq(pushTokens.deviceId, deviceId), eq(pushTokens.space, space)))
      const [r] = await db.delete(devices).where(and(eq(devices.deviceId, deviceId), eq(devices.ownerUserId, ownerUserId), inSpace(space))).returning()
      return r ? row(r) : undefined
    },
    async deleteOwner(ownerUserId, scope) {
      if (scope === "all") {
        await db.delete(pushTokens).where(eq(pushTokens.ownerUserId, ownerUserId))
        // Dev spaces' prefs rows carry the space in front of the owner key (prefsUserKey).
        await db.delete(teamPrefs).where(sql`${teamPrefs.userId} = ${ownerUserId} OR (${teamPrefs.space} <> '' AND ${teamPrefs.userId} = ${teamPrefs.space} || '|' || ${ownerUserId})`)
        return (await db.delete(devices).where(eq(devices.ownerUserId, ownerUserId)).returning()).map(row)
      }
      const { space } = scope
      await db.delete(pushTokens).where(and(eq(pushTokens.ownerUserId, ownerUserId), eq(pushTokens.space, space)))
      await db.delete(teamPrefs).where(and(eq(teamPrefs.userId, prefsUserKey(space, ownerUserId)), eq(teamPrefs.space, space)))
      return (await db.delete(devices).where(and(eq(devices.ownerUserId, ownerUserId), inSpace(space))).returning()).map(row)
    },
    async setPush(p) {
      const kinds = p.kinds.join(",")
      const mutedMacs = p.mutedMacs.length ? p.mutedMacs.join(",") : null
      const [r] = await db
        .insert(pushTokens)
        .values({ ...p, kinds, mutedMacs })
        .onConflictDoUpdate({
          target: pushTokens.deviceId,
          set: { ownerUserId: p.ownerUserId, token: p.token, environment: p.environment, topic: p.topic, kinds, mutedMacs, previews: p.previews, updatedAt: sql`now()` },
          setWhere: eq(pushTokens.space, p.space)
        })
        .returning()
      if (!r) throw new Error("push token row belongs to another build space")
      return pushRow(r)
    },
    async deletePush(space, deviceId) {
      await db.delete(pushTokens).where(and(eq(pushTokens.deviceId, deviceId), eq(pushTokens.space, space)))
    },
    async listOwnerPush(space, ownerUserId) {
      return (await db.select().from(pushTokens).where(and(eq(pushTokens.ownerUserId, ownerUserId), eq(pushTokens.space, space)))).map(pushRow)
    },
    async dropPushTokens(space, tokens) {
      if (tokens.length) await db.delete(pushTokens).where(and(inArray(pushTokens.token, [...tokens]), eq(pushTokens.space, space)))
    },
    async getPrefs(space, userId, teamId) {
      const [r] = await db
        .select()
        .from(teamPrefs)
        .where(and(eq(teamPrefs.userId, prefsUserKey(space, userId)), eq(teamPrefs.teamId, teamId), eq(teamPrefs.space, space)))
        .limit(1)
      return r ? { color: r.color, emoji: r.emoji, transparent: r.transparent && hasIcon(r.emoji) } : { ...NO_PREFS }
    },
    async putPrefs(space, userId, teamId, patch) {
      const set: Record<string, unknown> = { updatedAt: sql`now()` }
      if (patch.color !== undefined) set.color = patch.color
      if (patch.emoji !== undefined) set.emoji = patch.emoji
      if (patch.transparent !== undefined) set.transparent = patch.transparent
      const [r] = await db
        .insert(teamPrefs)
        .values({ userId: prefsUserKey(space, userId), teamId, space, color: patch.color ?? null, emoji: patch.emoji ?? null, transparent: patch.transparent ?? false })
        .onConflictDoUpdate({ target: [teamPrefs.userId, teamPrefs.teamId], set, setWhere: eq(teamPrefs.space, space) })
        .returning()
      return r ? { color: r.color, emoji: r.emoji, transparent: r.transparent && hasIcon(r.emoji) } : { ...NO_PREFS }
    },
    async listTeamScopes() {
      const r = await client.query<{ project: string | null; team_id: string; device_ids: Array<string> | null }>(
        `SELECT project, team_id, array_agg(device_id::text) FILTER (WHERE device_id IS NOT NULL) AS device_ids FROM (
           SELECT NULLIF(split_part(owner_user_id, ':', 1), owner_user_id) AS project, team_id, device_id FROM devices WHERE space = ''
           UNION ALL SELECT NULLIF(split_part(user_id, ':', 1), user_id) AS project, team_id, NULL FROM team_prefs WHERE space = ''
         ) t GROUP BY project, team_id`
      )
      return r.rows.map((x) => ({ project: x.project, teamId: x.team_id, deviceIds: x.device_ids ?? [] }))
    },
    close: () => client.end()
  }
}

/** In-memory store for tests (ENVIRONMENT=test, no Hyperdrive binding). Shared per isolate. */
const mem = { devices: new Map<string, Device>(), prefs: new Map<string, Prefs & { space: string }>(), push: new Map<string, PushRegistration>() }
const copyPush = (p: PushRegistration): PushRegistration => ({ ...p, kinds: [...p.kinds], mutedMacs: [...p.mutedMacs] })
/** A team prefs key, as the table's (user_id, team_id) primary key with prefsUserKey. */
const prefsKey = (space: string, userId: string, teamId: string) => `${prefsUserKey(space, userId)}\u0000${teamId}`
export const memoryStore = (): Store => ({
  async getDevice(space, id) {
    const d = mem.devices.get(id)
    return d && d.space === space ? { ...d } : undefined
  },
  async upsertDevice(d) {
    const prev = mem.devices.get(d.deviceId)
    if (prev && prev.ownerUserId !== d.ownerUserId) return prev.space !== d.space ? "other_space" : "not_owner"
    // The same owner's id in another space moves here, with its push token (Store).
    const movedFrom = prev && prev.space !== d.space ? prev.space : null
    const token = mem.push.get(d.deviceId)
    if (movedFrom !== null && token?.space === movedFrom) mem.push.set(d.deviceId, { ...token, space: d.space })
    const now = new Date().toISOString()
    const device: Device = {
      ...d,
      machineId: d.machineId === undefined ? (prev?.machineId ?? null) : d.machineId,
      modelKind: d.modelKind === undefined ? (prev?.modelKind ?? null) : d.modelKind,
      createdAt: prev?.createdAt ?? now,
      updatedAt: now,
      lastSeenAt: prev?.lastSeenAt ?? null
    }
    mem.devices.set(d.deviceId, device)
    return { device: { ...device }, previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null, movedFrom }
  },
  async claimSiblings(space, owner, machineId, ids) {
    const claimed: Array<string> = []
    for (const id of ids) {
      const d = mem.devices.get(id)
      if (!d || d.space !== space || d.ownerUserId !== owner || d.kind !== "mac" || (d.machineId !== null && d.machineId !== machineId)) continue
      if (d.machineId === null) mem.devices.set(id, { ...d, machineId })
      claimed.push(id)
    }
    return claimed
  },
  async listOwnerMacs(space, owner) {
    return [...mem.devices.values()].filter((d) => d.space === space && d.ownerUserId === owner && d.kind === "mac").sort((a, b) => a.name.localeCompare(b.name))
  },
  async listOwnerDevices(space, owner) {
    return [...mem.devices.values()]
      .filter((d) => d.space === space && d.ownerUserId === owner)
      .sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name))
      .map((d) => ({ ...d, push: mem.push.get(d.deviceId)?.space === space }))
  },
  async deleteDevice(space, id, owner) {
    const d = mem.devices.get(id)
    if (!d || d.space !== space) return undefined
    if (d.ownerUserId !== owner) return "not_owner"
    mem.devices.delete(id)
    if (mem.push.get(id)?.space === space) mem.push.delete(id)
    return { ...d }
  },
  async deleteOwner(owner, scope) {
    const hit = (space: string) => scope === "all" || space === scope.space
    const gone = [...mem.devices.values()].filter((d) => d.ownerUserId === owner && hit(d.space))
    for (const d of gone) mem.devices.delete(d.deviceId)
    for (const [k, p] of mem.push) if (p.ownerUserId === owner && hit(p.space)) mem.push.delete(k)
    for (const [k, p] of mem.prefs) if (hit(p.space) && k.startsWith(`${prefsUserKey(p.space, owner)}\u0000`)) mem.prefs.delete(k)
    return gone
  },
  async setPush(p) {
    const prev = mem.push.get(p.deviceId)
    if (prev && prev.space !== p.space) throw new Error("push token row belongs to another build space")
    const r = { ...p, kinds: [...p.kinds], mutedMacs: [...p.mutedMacs], updatedAt: new Date().toISOString() }
    mem.push.set(p.deviceId, r)
    return copyPush(r)
  },
  async deletePush(space, id) {
    if (mem.push.get(id)?.space === space) mem.push.delete(id)
  },
  async listOwnerPush(space, owner) {
    return [...mem.push.values()].filter((p) => p.space === space && p.ownerUserId === owner).map(copyPush)
  },
  async dropPushTokens(space, tokens) {
    for (const [k, p] of mem.push) if (p.space === space && tokens.includes(p.token)) mem.push.delete(k)
  },
  async getPrefs(space, u, t) {
    const p = mem.prefs.get(prefsKey(space, u, t))
    return p && p.space === space ? { color: p.color, emoji: p.emoji, transparent: p.transparent } : { ...NO_PREFS }
  },
  async putPrefs(space, u, t, patch) {
    const k = prefsKey(space, u, t)
    const cur = mem.prefs.get(k) ?? NO_PREFS
    const emoji = patch.emoji !== undefined ? patch.emoji : cur.emoji
    const next: Prefs = {
      color: patch.color !== undefined ? patch.color : cur.color,
      emoji,
      // As Postgres's read: never transparent without an icon.
      transparent: (patch.transparent !== undefined ? patch.transparent : cur.transparent) && hasIcon(emoji)
    }
    mem.prefs.set(k, { ...next, space })
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
    // Stable rows only: the old team hubs never held a dev build's devices.
    for (const d of mem.devices.values()) if (d.space === "") add(scope(d.ownerUserId), d.teamId, d.deviceId)
    for (const [k, p] of mem.prefs) if (p.space === "") add(scope(k.split("\u0000")[0]!), k.split("\u0000")[1]!)
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

export const openStore = async (env: Env): Promise<Store> => {
  // cmux-next-vitess (vitess-migration-DESIGN.md 2.3). pgStore stays only for a read of the old Postgres.
  if (env.PS_MYSQL) return vitessStore(env.PS_MYSQL)
  // Tests of the MySQL store's Worker behavior (test/schema-probe.test.ts) hand in a fake connection.
  if (env.ENVIRONMENT === "test" && env.TEST_MYSQL_CONN) return (await import("./store-mysql.ts")).mysqlStore(env.TEST_MYSQL_CONN)
  // Tests, and `wrangler dev` of the local (top-level) config: rows live in the isolate's memory.
  if (env.ENVIRONMENT === "test" || env.ENVIRONMENT === "local") return memoryStore()
  throw new Error("no database binding")
}
