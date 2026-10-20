import type { Env } from "../env.ts"
import { cloudEnvTag } from "../cloud-driver.ts"
import { meteredOwner } from "../model-gateway/routes.ts"
import { personalTeamIdFor } from "../domains/user.ts"

/**
 * The machine side of the Claude Code route (turn.ts, backend/chief-cc/bake.sh): one Freestyle VM per
 * Chief turn, made from the chief-cc snapshot (CHIEF_CC_SNAPSHOT: Claude Code, tailscale, the turn runner
 * and the model forward), joined to the tailnet with a one-use, pre-authorized, ephemeral key tagged
 * tag:agent-cloud (minted per VM with the Tailscale OAuth client CHIEF_CC_TS_OAUTH, scope auth_keys, that
 * tag only), so its model calls reach the sr2 gateway, which admits it by its tailnet identity. Deleted by
 * exact id after the turn; Freestyle's own timers (idle pause 300 s, ttl 30 min, run cap 15 min) are the
 * backstop for a turn whose object never came back. Keys, tokens and the VM's output are never logged:
 * errors carry only the step and the HTTP status.
 *
 * Personal route (Lawrence, 2026-10-20): only owners on CHIEF_CC_OWNERS (and on CHIEF_BRAIN_CLAUDE_OWNERS), only where
 * CHIEF_CC_ENABLED is "1" and both secrets and the snapshot are set. These turns use no Cloud model route
 * and are not charged to Cloud credits.
 */
const API = "https://api.freestyle.sh"
const CALL_MS = 30_000
export const BOOT_MS = 60_000

export const ccConfigured = (env: Env): boolean => env.CHIEF_CC_ENABLED === "1" && Boolean(env.CHIEF_CC_FREESTYLE_API_KEY && env.CHIEF_CC_TS_OAUTH && env.CHIEF_CC_SNAPSHOT) && cloudEnvTag(env.ENVIRONMENT) !== null
/**
 * This owner's turns run as Claude Code in a VM (the personal route), not on the Cloud model route: only an
 * owner named on CHIEF_CC_OWNERS (its user id or its personal team id, as meteredOwner) that is also a paid-model owner (its turns still count against the
 * owner's daily paid-turn cap).
 */
export const ccRoute = (env: Env, owner: string | null | undefined): boolean => {
  if (!owner || !ccConfigured(env)) return false
  const list = (env.CHIEF_CC_OWNERS ?? "").split(",").map((s) => s.trim()).filter(Boolean)
  return (list.includes(owner) || list.includes(personalTeamIdFor(owner))) && meteredOwner(env, owner)
}

export class CcError extends Error {}

const base = (env: Env) => (env.CHIEF_CC_FREESTYLE_API_URL || API).replace(/\/+$/, "")
const fs = async (env: Env, method: string, path: string, body?: unknown, ms = CALL_MS): Promise<Response> => {
  try {
    return await fetch(`${base(env)}${path}`, { method, redirect: "manual", signal: AbortSignal.timeout(ms), headers: { authorization: `Bearer ${env.CHIEF_CC_FREESTYLE_API_KEY}`, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  } catch {
    throw new CcError(`${method} ${path.split("/").slice(0, 3).join("/")}: no answer`)
  }
}

/** The VM's provider name: cmuxnp-<env>-ccb-<12 random> (FREESTYLE-NAMES; its own lane, no other sweep owns it). */
export const vmName = (env: Env): string => `cmuxnp-${cloudEnvTag(env.ENVIRONMENT)}-ccb-${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`

export const createVm = async (env: Env, name: string, meta: { agent: string; conversation: string; run: string }): Promise<string> => {
  const res = await fs(env, "POST", "/v5/vms", {
    slug: name,
    snapshotId: env.CHIEF_CC_SNAPSHOT,
    idleTimeoutSeconds: 300,
    maxRunSeconds: 900,
    ttlSeconds: 1800,
    automaticRestart: false,
    metadata: { cmux_chief_cc: meta.agent, cmux_conversation: meta.conversation, cmux_run: meta.run },
    // Out to the Internet only (the tailnet comes up inside the guest); nothing comes in.
    firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] }
  }, 120_000)
  const body = (await res.json().catch(() => null)) as { id?: string; vmId?: string } | null
  const id = body?.id ?? body?.vmId
  if (!res.ok || !id) throw new CcError(`create VM: ${res.status}`)
  return id
}

/** Runs `command` as root with `stdin`; the exit code and stdout (the guest's stderr is never read back). */
export const execRoot = async (env: Env, vm: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<{ exit: number; stdout: string }> => {
  const res = await fs(env, "POST", `/v5/vms/${encodeURIComponent(vm)}/exec-await`, { command, timeoutMs, linuxUser: "root", ...(stdin ? { stdin: b64(stdin) } : {}) }, timeoutMs + 15_000)
  if (res.status !== 200) {
    await res.body?.cancel().catch(() => undefined)
    throw new CcError(`exec: ${res.status}`)
  }
  const r = (await res.json().catch(() => ({}))) as { statusCode?: unknown; stdout?: unknown }
  return { exit: typeof r.statusCode === "number" ? r.statusCode : 124, stdout: typeof r.stdout === "string" ? r.stdout : "" }
}

/** Deletes by exact id (the tailnet node leaves first, best effort); true once the provider confirms (missing counts). */
export const removeVm = async (env: Env, vm: string): Promise<boolean> => {
  await execRoot(env, vm, "tailscale logout >/dev/null 2>&1 || true", null, 8_000).catch(() => undefined)
  const res = await fs(env, "DELETE", `/v5/vms/${encodeURIComponent(vm)}`).catch(() => null)
  await res?.body?.cancel().catch(() => undefined)
  return res !== null && (res.ok || res.status === 404)
}

const b64 = (bytes: Uint8Array): string => {
  let s = ""
  for (let i = 0; i < bytes.byteLength; i++) s += String.fromCharCode(bytes[i]!)
  return btoa(s)
}

let access: { token: string; until: number } | undefined
/** A Tailscale API access token from the OAuth client (cached in this isolate until 5 min before it expires). */
const tailnetAccess = async (env: Env): Promise<string> => {
  if (access && access.until > Date.now()) return access.token
  let c: { client_id?: string; client_secret?: string }
  try {
    c = JSON.parse(env.CHIEF_CC_TS_OAUTH ?? "") as typeof c
  } catch {
    throw new CcError("tailnet: the OAuth client secret is not JSON")
  }
  const res = await fetch("https://api.tailscale.com/api/v2/oauth/token", { method: "POST", signal: AbortSignal.timeout(CALL_MS), headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ client_id: c.client_id ?? "", client_secret: c.client_secret ?? "" }) }).catch(() => null)
  const body = (await res?.json().catch(() => null)) as { access_token?: string; expires_in?: number } | null
  if (!res?.ok || !body?.access_token) throw new CcError(`tailnet token: ${res?.status ?? "no answer"}`)
  access = { token: body.access_token, until: Date.now() + Math.max(60, (body.expires_in ?? 3600) - 300) * 1000 }
  return access.token
}

/** One key for one VM: single use, pre-authorized, ephemeral (the node goes when the VM goes), tag:agent-cloud, 10 min to use it. */
export const mintTailnetKey = async (env: Env): Promise<Uint8Array> => {
  const token = await tailnetAccess(env)
  const res = await fetch("https://api.tailscale.com/api/v2/tailnet/-/keys", {
    method: "POST",
    signal: AbortSignal.timeout(CALL_MS),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ capabilities: { devices: { create: { reusable: false, ephemeral: true, preauthorized: true, tags: ["tag:agent-cloud"] } } }, expirySeconds: 600, description: "cloud chief turn" })
  }).catch(() => null)
  const body = (await res?.json().catch(() => null)) as { key?: string } | null
  if (res?.status === 401) access = undefined
  if (!res?.ok || !body?.key) throw new CcError(`tailnet key: ${res?.status ?? "no answer"}`)
  return new TextEncoder().encode(body.key)
}
