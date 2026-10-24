import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError, freestyle } from "./vm.ts"

/**
 * Client sessions for the Chief's sandboxes (Lawrence, 2026-10-21; freestyle.sh/docs/vms/client-sessions): one
 * Freestyle identity per Chief, a VM grant only for the sandboxes it made, with allowedLinuxUsers set explicitly
 * (never null), and a short-lived access token minted, stored and rotated here. exec runs with that token
 * (header x-freestyle-identity-access-token), so it reaches only that VM as those users; the team key never
 * reaches a VM, the turn machine, the Chief or the Mac. The grant is revoked when the sandbox is deleted, and the
 * identity (its tokens and grants with it) when the Chief is archived. Tokens are never logged or returned.
 */
export const LINUX_USERS = ["root", "chief"] as const
const TOKEN_TTL_MS = 15 * 60_000
const ROTATE_BEFORE_MS = 3 * 60_000
const HEADER = "x-freestyle-identity-access-token"

type Access = { identity: string; token?: string; token_id?: string; expires_at?: number; granted: Array<string> }
const KEY = "cc_identity"

const read = (b: ChiefBrainDO): Access | null => {
  const raw = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, KEY).toArray()[0]?.value
  try {
    const a = JSON.parse(raw ?? "null") as Access | null
    return a && typeof a.identity === "string" ? { ...a, granted: Array.isArray(a.granted) ? a.granted : [] } : null
  } catch {
    return null
  }
}
const write = (b: ChiefBrainDO, a: Access | null) => (a ? writeConfig(b.sql, { [KEY]: JSON.stringify(a) }) : void b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, KEY))
const drain = async (res: Response | null) => void (await res?.body?.cancel().catch(() => undefined))

/** This Chief's identity, made on first use (one creation at a time, so two first calls share one identity). */
const making = new WeakMap<object, Promise<Access>>()
const identity = async (b: ChiefBrainDO): Promise<Access> => {
  const have = read(b)
  if (have) return have
  const busy = making.get(b.sql)
  if (busy) return busy
  const p = (async () => {
    const res = await freestyle(b.doEnv, "POST", "/v5/identities", {})
    const body = (await res.json().catch(() => null)) as { id?: unknown } | null
    if (!res.ok || typeof body?.id !== "string") throw new CcError(`identity: ${res.status}`)
    const a: Access = { identity: body.id, granted: [] }
    write(b, a)
    return a
  })().finally(() => making.delete(b.sql))
  making.set(b.sql, p)
  return p
}

/** Grants this Chief's identity VM `vm` as LINUX_USERS (once per VM). */
export const grant = async (b: ChiefBrainDO, vm: string, retried = false): Promise<void> => {
  const a = await identity(b)
  if (a.granted.includes(vm)) return
  const res = await freestyle(b.doEnv, "POST", `/v5/identities/${encodeURIComponent(a.identity)}/permissions/vm`, { vmId: vm, allowedLinuxUsers: [...LINUX_USERS] })
  await drain(res)
  // 404 on the grant: when the identity itself is gone at Freestyle (deleted outside the Worker), forget it and
  // grant once on a new one; a missing VM leaves the identity alone.
  if (res.status === 404 && !retried) {
    const who = await freestyle(b.doEnv, "GET", `/v5/identities/${encodeURIComponent(a.identity)}`, undefined, 10_000).catch(() => null)
    await drain(who)
    if (who?.status === 404) return write(b, null), grant(b, vm, true)
  }
  // 409: granted already (an earlier call whose answer was lost).
  if (!res.ok && res.status !== 409) throw new CcError(`grant: ${res.status}`)
  // Read again: only the identity this grant was made on records it, and nothing written meanwhile is lost.
  const now = read(b)
  if (now?.identity === a.identity && !now.granted.includes(vm)) write(b, { ...now, granted: [...now.granted, vm] })
}

/** Revokes the grant on `vm` (its sandbox is deleted); missing counts as revoked. */
export const revokeGrant = async (b: ChiefBrainDO, vm: string): Promise<void> => {
  const a = read(b)
  if (!a) return
  const res = await freestyle(b.doEnv, "DELETE", `/v5/identities/${encodeURIComponent(a.identity)}/permissions/vm/${encodeURIComponent(vm)}`).catch(() => null)
  await drain(res)
  const now = read(b)
  if (res && (res.ok || res.status === 404) && now?.identity === a.identity) write(b, { ...now, granted: now.granted.filter((x) => x !== vm) })
}

/** A token with at least ROTATE_BEFORE_MS left: the stored one, or a new one (the old one is revoked). */
const token = async (b: ChiefBrainDO): Promise<string> => {
  const a = await identity(b)
  if (a.token && (a.expires_at ?? 0) - Date.now() > ROTATE_BEFORE_MS) return a.token
  const expires = Date.now() + TOKEN_TTL_MS
  const res = await freestyle(b.doEnv, "POST", `/v5/identities/${encodeURIComponent(a.identity)}/tokens`, { expiresAt: new Date(expires).toISOString() })
  const body = (await res.json().catch(() => null)) as { id?: unknown; token?: unknown } | null
  if (!res.ok || typeof body?.token !== "string" || typeof body.id !== "string") throw new CcError(`token: ${res.status}`)
  if (a.token_id) await drain(await freestyle(b.doEnv, "DELETE", `/v5/identities/${encodeURIComponent(a.identity)}/tokens/${encodeURIComponent(a.token_id)}`).catch(() => null))
  const now = read(b)
  if (now?.identity === a.identity) write(b, { ...now, token: body.token, token_id: body.id, expires_at: expires })
  return body.token
}

const base = (b: ChiefBrainDO) => (b.doEnv.CHIEF_CC_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")

/** One call on a granted VM's exec or terminal routes with this Chief's identity token (never the team key). */
export const asChief = async (b: ChiefBrainDO, vm: string, method: string, path: string, body: unknown, ms: number): Promise<Response> => {
  await grant(b, vm)
  const t = await token(b)
  try {
    return await fetch(`${base(b)}/v5/vms/${encodeURIComponent(vm)}${path}`, { method, redirect: "manual", signal: AbortSignal.timeout(ms), headers: { [HEADER]: t, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  } catch {
    throw new CcError(`${method} ${path}: no answer`)
  }
}

export type ExecIn = { command: string; timeout_ms: number; user: (typeof LINUX_USERS)[number]; env?: Record<string, string>; stdin?: string }
/** exec-await on a sandbox as the Chief's identity: its exit code (124 when the timeout killed it), stdout and stderr. */
export const execAs = async (b: ChiefBrainDO, vm: string, x: ExecIn, retried = false): Promise<{ exit: number; stdout: string; stderr: string }> => {
  const res = await asChief(b, vm, "POST", "/exec-await", { command: x.command, timeoutMs: x.timeout_ms, linuxUser: x.user, ...(x.env ? { env: x.env } : {}), ...(x.stdin ? { stdin: x.stdin } : {}) }, x.timeout_ms + 15_000)
  // A token or grant Freestyle no longer has (revoked, expired, lost): forget both here and try once more.
  if ((res.status === 401 || res.status === 403) && !retried) {
    await drain(res)
    const a = read(b)
    if (a?.token_id) await drain(await freestyle(b.doEnv, "DELETE", `/v5/identities/${encodeURIComponent(a.identity)}/tokens/${encodeURIComponent(a.token_id)}`).catch(() => null))
    if (a) write(b, { identity: a.identity, granted: a.granted.filter((v) => v !== vm) })
    return execAs(b, vm, x, true)
  }
  if (res.status !== 200) {
    const why = ((await res.json().catch(() => null)) as { message?: unknown } | null)?.message
    throw new CcError(`exec: ${res.status}${typeof why === "string" ? ` ${why.slice(0, 200)}` : ""}`)
  }
  const r = (await res.json().catch(() => ({}))) as { statusCode?: unknown; stdout?: unknown; stderr?: unknown }
  return { exit: typeof r.statusCode === "number" ? r.statusCode : 124, stdout: typeof r.stdout === "string" ? r.stdout : "", stderr: typeof r.stderr === "string" ? r.stderr : "" }
}

/** The Chief is archived (or leaves the route): its identity goes, with every token and grant. */
export const revokeIdentity = async (b: ChiefBrainDO): Promise<boolean> => {
  const a = read(b)
  if (!a) return true
  const res = await freestyle(b.doEnv, "DELETE", `/v5/identities/${encodeURIComponent(a.identity)}`).catch(() => null)
  await drain(res)
  if (!res || !(res.ok || res.status === 404)) return false
  write(b, null)
  return true
}
