import type { Env } from "./env.ts"
import { handStub } from "./hand-api.ts"
import { HAND_ID } from "./hand-wire.ts"

/**
 * The hourly sweep of sandbox VMs (index.ts scheduled): every VM under this deployment's prefix with
 * a `cmux_hand` tag whose hand has no live row naming that exact VM (a create that timed out after
 * the provider made the VM, a hand removed while its delete failed) is deleted by its exact id. VMs
 * younger than 15 minutes are left alone (a sandbox being made has its row a moment later).
 */
const MIN_AGE_MS = 15 * 60_000
const PAGE = 100
const MAX_PAGES = 20

export const sweepSandboxVms = async (env: Env): Promise<{ seen: number; deleted: number; kept: number }> => {
  const key = env.HAND_FREESTYLE_API_KEY
  const prefix = env.CLOUD_NAME_PREFIX ?? ""
  if (!key || !/^cmuxnp-(dev|stg|prod)-cld-$/.test(prefix)) return { seen: 0, deleted: 0, kept: 0 }
  const base = (env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")
  const headers = { authorization: `Bearer ${key}` }
  let seen = 0
  let deleted = 0
  let kept = 0
  const done = new Set<string>()
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await fetch(`${base}/v5/vms?limit=${PAGE}&offset=${page * PAGE}`, { headers, redirect: "manual", signal: AbortSignal.timeout(20_000) })
    if (!res.ok) break
    const vms = ((await res.json()) as { vms?: Array<{ id?: string; slug?: string | null; createdAt?: string; metadata?: Record<string, unknown> | null }> }).vms ?? []
    // A list that ignores the offset gives the same page again: stop there.
    if (vms.every((v) => !v.id || done.has(v.id))) break
    for (const vm of vms) {
      if (!vm.id || done.has(vm.id)) continue
      done.add(vm.id)
      const hand = vm.metadata?.cmux_hand
      if (!vm.id || typeof hand !== "string" || !HAND_ID.test(hand) || !vm.slug?.startsWith(`${prefix}hand-`)) continue
      seen++
      if (Date.now() - Date.parse(vm.createdAt ?? "") < MIN_AGE_MS) continue
      if (await handStub(env, hand).ownsVm(vm.id).catch(() => true)) {
        kept++
        continue
      }
      const d = await fetch(`${base}/v5/vms/${encodeURIComponent(vm.id)}`, { method: "DELETE", headers, redirect: "manual", signal: AbortSignal.timeout(20_000) }).catch(() => null)
      if (d && (d.ok || d.status === 404)) deleted++
    }
    if (vms.length < PAGE) break
  }
  return { seen, deleted, kept }
}
