import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import type { CloudOpDef } from "@cmux/protocol"
import { Schema } from "effect"

/**
 * Guest devices on a host (plans/cmux-next/ios-next/b6-pairing.md sections 1 and 4.2): another
 * account's install the host owner accepted through a QR pairing. TeamDO owns socket admission
 * (`hostAccess` admits a guest as a `device`); the link keys live in the owner's `trust:` stream.
 * Written only by UserDO's pairing handlers over DO RPC (system ops).
 */

export interface HostGuest {
  readonly user: string
  readonly offer_id: string
  readonly at: number
}

export interface HostGuestsState {
  /** host id -> install id -> guest. */
  readonly host_guests?: Readonly<Record<string, Readonly<Record<string, HostGuest>>>>
}

// No import of common.ts: it imports hostGuestInternalOps from here at load (a cycle would hit the TDZ).
const reject = (code: string, message: string) => ({ ok: false as const, code, message })

export const MAX_GUESTS_PER_HOST = 64
const ID = /^[A-Za-z0-9_]{3,80}$/

export const guestOf = (state: HostGuestsState, host: string, install: string | undefined): HostGuest | undefined =>
  install ? state.host_guests?.[host]?.[install] : undefined

export const reduceHostGuest = <S extends HostGuestsState>(state: S, op: string, params: unknown, ctx: ReduceContext, hostExists: (host: string) => boolean): ReduceResult<S> => {
  const p = (params ?? {}) as { host?: unknown; install?: unknown; user?: unknown; offer_id?: unknown }
  if (typeof p.host !== "string" || !ID.test(p.host) || typeof p.install !== "string" || !ID.test(p.install)) return reject("validation.invalid", "host and install are ids")
  const host = p.host
  const install = p.install
  const guests = state.host_guests?.[host] ?? {}
  if (op === "host.guest.remove") {
    if (!guests[install]) return { ok: true, state, value: { host, install }, changed: false }
    const { [install]: _gone, ...rest } = guests
    const { [host]: _host, ...others } = state.host_guests ?? {}
    return { ok: true, state: { ...state, host_guests: Object.keys(rest).length ? { ...others, [host]: rest } : others }, value: { host, install } }
  }
  if (typeof p.user !== "string" || !ID.test(p.user) || typeof p.offer_id !== "string" || p.offer_id.length > 64) return reject("validation.invalid", "user and offer_id are required")
  if (!hostExists(host)) return reject("selector.not_found", "host not found")
  if (guests[install]?.offer_id === p.offer_id && guests[install]?.user === p.user) return { ok: true, state, value: { host, install }, changed: false }
  if (!guests[install] && Object.keys(guests).length >= MAX_GUESTS_PER_HOST) return reject("validation.invalid", `at most ${MAX_GUESTS_PER_HOST} guest devices per host`)
  const next = { ...guests, [install]: { user: p.user, offer_id: p.offer_id, at: ctx.now } }
  return { ok: true, state: { ...state, host_guests: { ...(state.host_guests ?? {}), [host]: next } }, value: { host, install } }
}

const def = (name: "host.guest.set" | "host.guest.remove"): CloudOpDef =>
  ({
    name,
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-shared",
    target: "host",
    principals: ["system"],
    params: Schema.Unknown,
    result: Schema.Unknown,
    errors: [],
    docs: name === "host.guest.set" ? "Internal: the host owner accepted another account's device (B6 pairing)." : "Internal: a guest device lost access to a host (B6 pairing).",
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

export const hostGuestInternalOps: ReadonlyArray<CloudOpDef> = [def("host.guest.set"), def("host.guest.remove")]
