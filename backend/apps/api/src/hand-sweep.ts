import type { Env } from "./env.ts"
import { handStub } from "./hand-api.ts"
import { PROVIDERS } from "./hand-providers.ts"
import { SANDBOX_PREFIX } from "./hand-sandbox.ts"
import { HAND_ID } from "./hand-wire.ts"

/**
 * The hourly sweep of sandbox machines (index.ts scheduled), on every provider that is set up: a
 * machine with this deployment's prefix, a hand tag and this deployment's origin whose hand row no
 * longer holds it (an expired code, a failed install, a create that timed out after the provider
 * made it, a removed hand whose delete failed) is deleted by its exact id. Machines younger than 15
 * minutes, or without a readable creation time, are left alone; a failed lookup keeps the machine.
 */
const MIN_AGE_MS = 15 * 60_000

export const sweepSandboxVms = async (env: Env): Promise<{ seen: number; deleted: number; kept: number }> => {
  const prefix = env.CLOUD_NAME_PREFIX ?? ""
  const origin = (env.CLOUD_API_ORIGIN ?? "").replace(/\/$/, "")
  let seen = 0
  let deleted = 0
  let kept = 0
  if (!SANDBOX_PREFIX.test(prefix) || !origin) return { seen, deleted, kept }
  for (const provider of Object.values(PROVIDERS).filter((p) => p.canManage(env))) {
    for (const m of await provider.list(env, prefix)) {
      if (!m.hand || !HAND_ID.test(m.hand) || m.deployment !== origin) continue
      seen++
      if (!Number.isFinite(m.created_at) || Date.now() - m.created_at < MIN_AGE_MS) continue
      const state = await handStub(env, m.hand).ownsVm(m.id, provider.id).catch(() => "unknown" as const)
      if (state !== "gone") {
        kept++
        continue
      }
      if (await provider.remove(env, m.id)) deleted++
    }
  }
  return { seen, deleted, kept }
}
