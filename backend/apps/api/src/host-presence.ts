/**
 * The `host:<host>` stream state (b1-control-do.md section 4). HostDO is its only writer: socket
 * accept and close write `online`/`offline` and the attached devices; the Mac's own facts
 * (`sleeping`, `paused`, caps) arrive as `host.presence.set` / `host.caps.set` ops on its socket.
 * Pure functions: each returns the next state and the event params, or null for no change.
 */

export type HostPresence = "online" | "offline" | "sleeping" | "paused"

export interface HostDevice {
  readonly install: string
  readonly platform: string
  readonly app_version: string
  readonly active: boolean
  readonly since: number
}

export interface HostCaps {
  readonly proto: { readonly min: number; readonly max: number }
  readonly caps: ReadonlyArray<string>
  readonly cmux_version?: string
}

export interface HostStreamState {
  readonly host: string
  readonly presence: HostPresence
  readonly viewers: number
  readonly devices: ReadonlyArray<HostDevice>
  readonly caps: HostCaps | null
  readonly at: number
}

export interface HostChange {
  readonly op: "host.presence.set" | "host.caps.set" | "host.device.set" | "host.device.remove"
  readonly params: Record<string, unknown>
  readonly state: HostStreamState
}

export const initialHostState = (host: string, now: number): HostStreamState => ({ host, presence: "offline", viewers: 0, devices: [], caps: null, at: now })

const viewersOf = (devices: ReadonlyArray<HostDevice>) => devices.filter((d) => d.active).length

const presenceChange = (s: HostStreamState, presence: HostPresence, devices: ReadonlyArray<HostDevice>, now: number): HostChange | null => {
  const viewers = viewersOf(devices)
  if (presence === s.presence && viewers === s.viewers) return null
  const state = { ...s, presence, viewers, devices, at: now }
  return { op: "host.presence.set", params: { host: s.host, presence, viewers, at: now }, state }
}

/** The Mac's socket opened or closed. Closing drops Mac-only facts (sleeping, paused) with it. */
export const macConnected = (s: HostStreamState, connected: boolean, now: number): HostChange | null => presenceChange(s, connected ? "online" : "offline", s.devices, now)

/** `host.presence.set` from the Mac: only `online`, `sleeping` or `paused` while it is connected. */
export const macPresence = (s: HostStreamState, presence: unknown, now: number): HostChange | null | { error: string } => {
  if (presence !== "online" && presence !== "sleeping" && presence !== "paused") return { error: "presence must be online, sleeping or paused" }
  return presenceChange(s, presence, s.devices, now)
}

const CAP = /^[a-z][a-z0-9.-]{0,63}$/

/** `host.caps.set` from the Mac (validated: versions, caps grammar, at most 64 caps). */
export const macCaps = (s: HostStreamState, params: Record<string, unknown>, now: number): HostChange | null | { error: string } => {
  const proto = params.proto as { min?: unknown; max?: unknown } | undefined
  const caps = params.caps
  if (!proto || !Number.isInteger(proto.min) || !Number.isInteger(proto.max) || (proto.min as number) < 1 || (proto.max as number) < (proto.min as number)) return { error: "proto needs integer min <= max" }
  if (!Array.isArray(caps) || caps.length > 64 || !caps.every((c) => typeof c === "string" && CAP.test(c))) return { error: "caps must be at most 64 capability names" }
  const version = params.cmux_version
  if (version !== undefined && (typeof version !== "string" || version.length > 64)) return { error: "cmux_version must be a short string" }
  const next: HostCaps = { proto: { min: proto.min as number, max: proto.max as number }, caps: [...(caps as Array<string>)], ...(typeof version === "string" ? { cmux_version: version } : {}) }
  if (JSON.stringify(next) === JSON.stringify(s.caps)) return null
  return { op: "host.caps.set", params: { host: s.host, ...next }, state: { ...s, caps: next, at: now } }
}

/** A device attached (hello) or changed its active flag (`presence.set`). */
export const deviceSet = (s: HostStreamState, device: HostDevice, now: number): Array<HostChange> => {
  const old = s.devices.find((d) => d.install === device.install)
  const kept = old ? { ...device, since: old.since } : device
  if (old && JSON.stringify(old) === JSON.stringify(kept)) return []
  const devices = [...s.devices.filter((d) => d.install !== device.install), kept].sort((a, b) => (a.install < b.install ? -1 : 1))
  const set: HostChange = { op: "host.device.set", params: { host: s.host, device: kept }, state: { ...s, devices, at: now } }
  const p = presenceChange(set.state, s.presence, devices, now)
  return p ? [set, p] : [set]
}

/** A device's socket closed. */
export const deviceRemove = (s: HostStreamState, install: string, now: number): Array<HostChange> => {
  if (!s.devices.some((d) => d.install === install)) return []
  const devices = s.devices.filter((d) => d.install !== install)
  const rm: HostChange = { op: "host.device.remove", params: { host: s.host, install }, state: { ...s, devices, at: now } }
  const p = presenceChange(rm.state, s.presence, devices, now)
  return p ? [rm, p] : [rm]
}
