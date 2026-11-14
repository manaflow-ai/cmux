import { hasIcon, NO_PREFS, prefsUserKey, PUSH_KINDS, type Device, type PushKind, type PushRegistration, type Store } from "./store-types.ts"

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
  space: string
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
  space: string
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
  space: r.space,
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
  space: r.space,
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

/**
 * cmux-mobile-api's store on PlanetScale MySQL cmux-next-vitess (tables `mobile_*`, drizzle-mysql 0002_mobile, and
 * 0004_mobile_build_space for the `space` columns). Every statement names the caller's build space.
 */
export const mysqlStore = async (conn: MysqlConn): Promise<Store> => {
  await conn.query("SET time_zone = '+00:00'")
  const rows = async <T>(sql: string, values: Array<unknown> = []): Promise<Array<T>> => (await conn.query(sql, values))[0] as Array<T>
  /** The row of an id in any space: only upsertDevice reads it, to refuse an id another space holds. */
  const anyDevice = async (deviceId: string) => (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE device_id = ? LIMIT 1", [uuid(deviceId)])).map(device)[0]
  const getDevice = async (space: string, deviceId: string) =>
    (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE device_id = ? AND space = ? LIMIT 1", [uuid(deviceId), space])).map(device)[0]
  const prefs = async (space: string, userId: string, teamId: string) => {
    const [r] = await rows<{ color: string | null; emoji: string | null; transparent: number }>(
      "SELECT color, emoji, transparent FROM mobile_team_prefs WHERE user_id = ? AND team_id = ? AND space = ? LIMIT 1",
      [prefsUserKey(space, userId), teamId, space]
    )
    return r ? { color: r.color, emoji: r.emoji, transparent: Number(r.transparent) !== 0 && hasIcon(r.emoji) } : { ...NO_PREFS }
  }
  return {
    getDevice,
    async upsertDevice(d) {
      const id = uuid(d.deviceId)
      const prev = await anyDevice(id)
      if (prev && prev.space !== d.space) return "other_space"
      if (prev && prev.ownerUserId !== d.ownerUserId) return "not_owner"
      // INSERT IGNORE then an owner- and space-guarded UPDATE: a racing registration by another owner or space keeps its row.
      await conn.query(
        "INSERT IGNORE INTO mobile_devices (device_id, space, owner_user_id, team_id, kind, name, wg_public_key, machine_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [id, d.space, d.ownerUserId, d.teamId, d.kind, d.name, d.wgPublicKey, d.machineId ?? null]
      )
      const machine = d.machineId === undefined ? "" : ", machine_id = ?"
      await conn.query(
        `UPDATE mobile_devices SET team_id = ?, kind = ?, name = ?, wg_public_key = ?${machine}, updated_at = CURRENT_TIMESTAMP(3) WHERE device_id = ? AND owner_user_id = ? AND space = ?`,
        [d.teamId, d.kind, d.name, d.wgPublicKey, ...(d.machineId === undefined ? [] : [d.machineId]), id, d.ownerUserId, d.space]
      )
      const now = await anyDevice(id)
      if (!now) return "not_owner"
      if (now.space !== d.space) return "other_space"
      if (now.ownerUserId !== d.ownerUserId) return "not_owner"
      return { device: now, previousTeamId: prev && prev.teamId !== d.teamId ? prev.teamId : null }
    },
    async claimSiblings(space, ownerUserId, machineId, deviceIds) {
      if (!deviceIds.length) return []
      const ids = deviceIds.map(uuid)
      await conn.query(
        `UPDATE mobile_devices SET machine_id = ? WHERE space = ? AND owner_user_id = ? AND kind = 'mac' AND machine_id IS NULL AND device_id IN (${marks(ids.length)})`,
        [machineId, space, ownerUserId, ...ids]
      )
      const rs = await rows<{ device_id: string }>(
        `SELECT device_id FROM mobile_devices WHERE space = ? AND owner_user_id = ? AND kind = 'mac' AND machine_id = ? AND device_id IN (${marks(ids.length)})`,
        [space, ownerUserId, machineId, ...ids]
      )
      return rs.map((r) => r.device_id)
    },
    async listOwnerMacs(space, ownerUserId) {
      return (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE owner_user_id = ? AND space = ? AND kind = 'mac' ORDER BY name", [ownerUserId, space])).map(device)
    },
    async listOwnerDevices(space, ownerUserId) {
      const rs = await rows<DeviceRow & { token: string | null }>(
        "SELECT d.*, p.token FROM mobile_devices d LEFT JOIN mobile_push_tokens p ON p.device_id = d.device_id AND p.space = d.space WHERE d.owner_user_id = ? AND d.space = ? ORDER BY d.kind, d.name",
        [ownerUserId, space]
      )
      return rs.map((r) => ({ ...device(r), push: !!r.token }))
    },
    async deleteDevice(space, deviceId, ownerUserId) {
      const prev = await getDevice(space, deviceId)
      if (!prev) return undefined
      if (prev.ownerUserId !== ownerUserId) return "not_owner"
      await conn.query("DELETE FROM mobile_push_tokens WHERE device_id = ? AND space = ?", [prev.deviceId, space])
      const [res] = await conn.query("DELETE FROM mobile_devices WHERE device_id = ? AND owner_user_id = ? AND space = ?", [prev.deviceId, ownerUserId, space])
      return (res as { affectedRows: number }).affectedRows > 0 ? prev : undefined
    },
    async deleteOwner(ownerUserId, scope) {
      if (scope === "all") {
        const gone = (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE owner_user_id = ?", [ownerUserId])).map(device)
        await conn.query("DELETE FROM mobile_push_tokens WHERE owner_user_id = ?", [ownerUserId])
        // Dev spaces' prefs rows carry the space in front of the owner key (prefsUserKey).
        await conn.query("DELETE FROM mobile_team_prefs WHERE user_id = ? OR (space <> '' AND user_id = CONCAT(space, '|', ?))", [ownerUserId, ownerUserId])
        await conn.query("DELETE FROM mobile_devices WHERE owner_user_id = ?", [ownerUserId])
        return gone
      }
      const { space } = scope
      const gone = (await rows<DeviceRow>("SELECT * FROM mobile_devices WHERE owner_user_id = ? AND space = ?", [ownerUserId, space])).map(device)
      await conn.query("DELETE FROM mobile_push_tokens WHERE owner_user_id = ? AND space = ?", [ownerUserId, space])
      await conn.query("DELETE FROM mobile_team_prefs WHERE user_id = ? AND space = ?", [prefsUserKey(space, ownerUserId), space])
      await conn.query("DELETE FROM mobile_devices WHERE owner_user_id = ? AND space = ?", [ownerUserId, space])
      return gone
    },
    async setPush(p) {
      const id = uuid(p.deviceId)
      const kinds = p.kinds.join(",")
      const mutedMacs = p.mutedMacs.length ? p.mutedMacs.join(",") : null
      // INSERT IGNORE then a space-guarded UPDATE: a row of another space is never overwritten.
      await conn.query(
        "INSERT IGNORE INTO mobile_push_tokens (device_id, space, owner_user_id, token, environment, topic, kinds, muted_macs, previews) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, p.space, p.ownerUserId, p.token, p.environment, p.topic, kinds, mutedMacs, p.previews]
      )
      await conn.query(
        `UPDATE mobile_push_tokens SET owner_user_id = ?, token = ?, environment = ?, topic = ?, kinds = ?, muted_macs = ?, previews = ?, updated_at = CURRENT_TIMESTAMP(3)
         WHERE device_id = ? AND space = ?`,
        [p.ownerUserId, p.token, p.environment, p.topic, kinds, mutedMacs, p.previews, id, p.space]
      )
      const [r] = await rows<PushRowDb>("SELECT * FROM mobile_push_tokens WHERE device_id = ? AND space = ?", [id, p.space])
      if (!r) throw new Error("push token row belongs to another build space")
      return push(r)
    },
    async deletePush(space, deviceId) {
      await conn.query("DELETE FROM mobile_push_tokens WHERE device_id = ? AND space = ?", [uuid(deviceId), space])
    },
    async listOwnerPush(space, ownerUserId) {
      return (await rows<PushRowDb>("SELECT * FROM mobile_push_tokens WHERE owner_user_id = ? AND space = ?", [ownerUserId, space])).map(push)
    },
    async dropPushTokens(space, tokens) {
      if (tokens.length) await conn.query(`DELETE FROM mobile_push_tokens WHERE space = ? AND token IN (${marks(tokens.length)})`, [space, ...tokens])
    },
    getPrefs: prefs,
    async putPrefs(space, userId, teamId, patch) {
      const key = prefsUserKey(space, userId)
      const set = ["updated_at = CURRENT_TIMESTAMP(3)"]
      const values: Array<unknown> = []
      if (patch.color !== undefined) (set.push("color = ?"), values.push(patch.color))
      if (patch.emoji !== undefined) (set.push("emoji = ?"), values.push(patch.emoji))
      if (patch.transparent !== undefined) (set.push("transparent = ?"), values.push(patch.transparent))
      // The key already carries a dev space (prefsUserKey), so (user_id, team_id) never names another space's row.
      await conn.query(
        `INSERT INTO mobile_team_prefs (user_id, team_id, space, color, emoji, transparent) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE ${set.join(", ")}`,
        [key, teamId, space, patch.color ?? null, patch.emoji ?? null, patch.transparent ?? false, ...values]
      )
      return prefs(space, userId, teamId)
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
      // Stable rows only: the old team hubs never held a dev build's devices.
      for (const r of await rows<{ owner_user_id: string; team_id: string; device_id: string }>("SELECT owner_user_id, team_id, device_id FROM mobile_devices WHERE space = ''"))
        add(r.owner_user_id, r.team_id, r.device_id)
      for (const r of await rows<{ user_id: string; team_id: string }>("SELECT user_id, team_id FROM mobile_team_prefs WHERE space = ''")) add(r.user_id, r.team_id)
      return [...out.values()]
    },
    close: () => conn.end()
  }
}
