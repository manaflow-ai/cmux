import { hasIcon, NO_PREFS, PUSH_KINDS, type Device, type PushKind, type PushRegistration, type Store } from "./store-types.ts"

/**
 * The part of a mysql2/promise connection the store uses. The caller opens it with `dateStrings: true`
 * (datetime columns come back as "YYYY-MM-DD HH:MM:SS.mmm" in UTC), so this file imports no driver and
 * the backend's MySQL tests can drive it with their own connection.
 */
export interface MysqlConn {
  query(sql: string, values?: Array<unknown>): Promise<[unknown, unknown]>
  end(): Promise<void>
}

type DeviceRow = {
  device_id: string
  owner_user_id: string
  team_id: string
  kind: "mac" | "phone"
  name: string
  wg_public_key: string | null
  machine_id: string | null
  created_at: string
  updated_at: string
  last_seen_at: string | null
}

type PushRowDb = {
  device_id: string
  owner_user_id: string
  token: string
  environment: "sandbox" | "production"
  topic: string
  kinds: string
  muted_macs: string | null
  previews: number | null
  updated_at: string
}

/** "2026-10-28 06:41:36.122" (UTC) to "2026-10-28T06:41:36.122Z". */
const iso = (s: string): string => `${s.replace(" ", "T")}${s.includes(".") ? "" : ".000"}Z`
/** Postgres stored uuids lower case and compared them case-insensitively; ascii_bin columns need one form. */
const uuid = (id: string): string => id.toLowerCase()

const device = (r: DeviceRow): Device => ({
  deviceId: r.device_id,
  ownerUserId: r.owner_user_id,
  teamId: r.team_id,
  kind: r.kind,
  name: r.name,
  wgPublicKey: r.wg_public_key,
  machineId: r.machine_id,
  createdAt: iso(r.created_at),
  updatedAt: iso(r.updated_at),
  lastSeenAt: r.last_seen_at ? iso(r.last_seen_at) : null
})

const push = (r: PushRowDb): PushRegistration => ({
  deviceId: r.device_id,
  ownerUserId: r.owner_user_id,
  token: r.token,
  environment: r.environment,
  topic: r.topic,
  kinds: r.kinds.split(",").filter((k): k is PushKind => (PUSH_KINDS as ReadonlyArray<string>).includes(k)),
  mutedMacs: (r.muted_macs ?? "").split(",").filter(Boolean),
  previews: r.previews === null ? true : Number(r.previews) !== 0,
  updatedAt: iso(r.updated_at)
})

const marks = (n: number) => Array.from({ length: n }, () => "?").join(", ")

/** cmux-mobile-api's store on PlanetScale MySQL cmux-next-vitess (tables `mobile_*`, drizzle-mysql 0002_mobile). */
export const mysqlStore = async (conn: MysqlConn): Promise<Store> => {
  await conn.query("SET time_zone = '+00:00'")
  const rows = async <T>(sql: string, values: Array<unknown> = []): Promise<Array<T>> => (await conn.query(sql, values))[0] as Array<T>
  const getDevice = async (deviceId: string) => (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE device_id = ? LIMIT 1", [uuid(deviceId)])).map(device)[0]
  const prefs = async (userId: string, teamId: string) => {
    const [r] = await rows<{ color: string | null; emoji: string | null; transparent: number }>(
      "SELECT color, emoji, transparent FROM mobile_team_prefs WHERE user_id = ? AND team_id = ? LIMIT 1",
      [userId, teamId]
    )
    return r ? { color: r.color, emoji: r.emoji, transparent: Number(r.transparent) !== 0 && hasIcon(r.emoji) } : { ...NO_PREFS }
  }
  return {
    getDevice,
    async upsertDevice(d) {
      const id = uuid(d.deviceId)
      const prev = await getDevice(id)
      if (prev && prev.ownerUserId !== d.ownerUserId) return "not_owner"
      // INSERT IGNORE then an owner-guarded UPDATE: a racing registration by another owner keeps its row.
      await conn.query(
        "INSERT IGNORE INTO mobile_devices (device_id, owner_user_id, team_id, kind, name, wg_public_key, machine_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [id, d.ownerUserId, d.teamId, d.kind, d.name, d.wgPublicKey, d.machineId ?? null]
      )
      const machine = d.machineId === undefined ? "" : ", machine_id = ?"
      await conn.query(
        `UPDATE mobile_devices SET team_id = ?, kind = ?, name = ?, wg_public_key = ?${machine}, updated_at = CURRENT_TIMESTAMP(3) WHERE device_id = ? AND owner_user_id = ?`,
        [d.teamId, d.kind, d.name, d.wgPublicKey, ...(d.machineId === undefined ? [] : [d.machineId]), id, d.ownerUserId]
      )
      const now = await getDevice(id)
      if (!now || now.ownerUserId !== d.ownerUserId) return "not_owner"
      return { device: now, previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
    },
    async claimSiblings(ownerUserId, machineId, deviceIds) {
      if (!deviceIds.length) return []
      const ids = deviceIds.map(uuid)
      await conn.query(
        `UPDATE mobile_devices SET machine_id = ? WHERE owner_user_id = ? AND kind = 'mac' AND machine_id IS NULL AND device_id IN (${marks(ids.length)})`,
        [machineId, ownerUserId, ...ids]
      )
      const rs = await rows<{ device_id: string }>(
        `SELECT device_id FROM mobile_devices WHERE owner_user_id = ? AND kind = 'mac' AND machine_id = ? AND device_id IN (${marks(ids.length)})`,
        [ownerUserId, machineId, ...ids]
      )
      return rs.map((r) => r.device_id)
    },
    async listOwnerMacs(ownerUserId) {
      return (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE owner_user_id = ? AND kind = 'mac' ORDER BY name", [ownerUserId])).map(device)
    },
    async listOwnerDevices(ownerUserId) {
      const rs = await rows<DeviceRow & { token: string | null }>(
        "SELECT d.*, p.token FROM mobile_devices d LEFT JOIN mobile_push_tokens p ON p.device_id = d.device_id WHERE d.owner_user_id = ? ORDER BY d.kind, d.name",
        [ownerUserId]
      )
      return rs.map((r) => ({ ...device(r), push: !!r.token }))
    },
    async deleteDevice(deviceId, ownerUserId) {
      const prev = await getDevice(deviceId)
      if (!prev) return undefined
      if (prev.ownerUserId !== ownerUserId) return "not_owner"
      await conn.query("DELETE FROM mobile_push_tokens WHERE device_id = ?", [prev.deviceId])
      const [res] = await conn.query("DELETE FROM mobile_devices WHERE device_id = ? AND owner_user_id = ?", [prev.deviceId, ownerUserId])
      return (res as { affectedRows: number }).affectedRows > 0 ? prev : undefined
    },
    async deleteOwner(ownerUserId) {
      const gone = (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE owner_user_id = ?", [ownerUserId])).map(device)
      await conn.query("DELETE FROM mobile_push_tokens WHERE owner_user_id = ?", [ownerUserId])
      await conn.query("DELETE FROM mobile_team_prefs WHERE user_id = ?", [ownerUserId])
      await conn.query("DELETE FROM mobile_devices WHERE owner_user_id = ?", [ownerUserId])
      return gone
    },
    async setPush(p) {
      const id = uuid(p.deviceId)
      const kinds = p.kinds.join(",")
      const mutedMacs = p.mutedMacs.length ? p.mutedMacs.join(",") : null
      await conn.query(
        `INSERT INTO mobile_push_tokens (device_id, owner_user_id, token, environment, topic, kinds, muted_macs, previews) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE owner_user_id = VALUES(owner_user_id), token = VALUES(token), environment = VALUES(environment), topic = VALUES(topic),
           kinds = VALUES(kinds), muted_macs = VALUES(muted_macs), previews = VALUES(previews), updated_at = CURRENT_TIMESTAMP(3)`,
        [id, p.ownerUserId, p.token, p.environment, p.topic, kinds, mutedMacs, p.previews]
      )
      return push((await rows<PushRowDb>("SELECT * FROM mobile_push_tokens WHERE device_id = ?", [id]))[0]!)
    },
    async deletePush(deviceId) {
      await conn.query("DELETE FROM mobile_push_tokens WHERE device_id = ?", [uuid(deviceId)])
    },
    async listOwnerPush(ownerUserId) {
      return (await rows<PushRowDb>("SELECT * FROM mobile_push_tokens WHERE owner_user_id = ?", [ownerUserId])).map(push)
    },
    async dropPushTokens(tokens) {
      if (tokens.length) await conn.query(`DELETE FROM mobile_push_tokens WHERE token IN (${marks(tokens.length)})`, [...tokens])
    },
    getPrefs: prefs,
    async putPrefs(userId, teamId, patch) {
      const set = ["updated_at = CURRENT_TIMESTAMP(3)"]
      const values: Array<unknown> = []
      if (patch.color !== undefined) (set.push("color = ?"), values.push(patch.color))
      if (patch.emoji !== undefined) (set.push("emoji = ?"), values.push(patch.emoji))
      if (patch.transparent !== undefined) (set.push("transparent = ?"), values.push(patch.transparent))
      await conn.query(
        `INSERT INTO mobile_team_prefs (user_id, team_id, color, emoji, transparent) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE ${set.join(", ")}`,
        [userId, teamId, patch.color ?? null, patch.emoji ?? null, patch.transparent ?? false, ...values]
      )
      return prefs(userId, teamId)
    },
    async listTeamScopes() {
      const scope = (owner: string) => (owner.includes(":") ? owner.slice(0, owner.indexOf(":")) : null)
      const out = new Map<string, { project: string | null; teamId: string; deviceIds: Array<string> }>()
      const add = (owner: string, teamId: string, deviceId?: string) => {
        const project = scope(owner)
        const k = `${project}\u0000${teamId}`
        const r = out.get(k) ?? { project, teamId, deviceIds: [] }
        if (deviceId) r.deviceIds.push(deviceId)
        out.set(k, r)
      }
      for (const r of await rows<{ owner_user_id: string; team_id: string; device_id: string }>("SELECT owner_user_id, team_id, device_id FROM mobile_devices")) add(r.owner_user_id, r.team_id, r.device_id)
      for (const r of await rows<{ user_id: string; team_id: string }>("SELECT user_id, team_id FROM mobile_team_prefs")) add(r.user_id, r.team_id)
      return [...out.values()]
    },
    close: () => conn.end()
  }
}
