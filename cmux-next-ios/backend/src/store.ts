import type { Env } from "./env.ts"
import { hasIcon, NO_PREFS, type Device, type Prefs, type PushRegistration, type Store } from "./store-types.ts"

export * from "./store-types.ts"

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
  // Loaded lazily: only the deployed Worker needs the driver.
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
  // cmux-next-vitess (vitess-migration-DESIGN.md 2.3); the mobile service has no database of its own.
  if (env.PS_MYSQL) return vitessStore(env.PS_MYSQL)
  // Tests, and `wrangler dev` of the local (top-level) config: rows live in the isolate's memory.
  if (env.ENVIRONMENT === "test" || env.ENVIRONMENT === "local") return Promise.resolve(memoryStore())
  throw new Error("no database binding")
}
