import { FreestyleError, type FreestyleNetworkApi } from "./freestyle-client.ts"
import { MANAGED_MARKER, parseExpiry } from "./freestyle-plan.ts"
import type { ActionOutcome } from "./reconcile.ts"

/**
 * Deletes EXPIRED development or staging network resources (Lawrence,
 * 2026-10-02: dev/staging share the production Freestyle account under the
 * `cmuxnp-dev-` / `cmuxnp-staging-` prefixes with an expiry stamp; an automatic
 * cleanup deletes only those prefixes once expired, never anything else).
 *
 * A resource is deleted only when ALL of these hold:
 * - VPC or tunnel: its slug starts with `cmuxnp-<env>-` and its display name
 *   carries `exp=<seconds>` in the past;
 * - rule: its description starts with `cmux-np/v1 env=<env> `, carries an
 *   expiry in the past, and its team has no unexpired VPC (a live team's rules
 *   are never removed: rule descriptions cannot be refreshed).
 * Resources without an expiry stamp are never touched. Production has no
 * cleanup: `env` must be dev or staging.
 */
export const cleanupExpired = async (api: FreestyleNetworkApi, env: "dev" | "staging", nowMs: number = Date.now()): Promise<ReadonlyArray<ActionOutcome>> => {
  if (env !== "dev" && env !== "staging") throw new Error(`cleanup runs only for dev and staging, not ${String(env)}`)
  const now = Math.floor(nowMs / 1000)
  const slugPrefix = `cmuxnp-${env}-`
  const rulePrefix = `${MANAGED_MARKER} env=${env} `
  const expired = (text: string | null | undefined) => {
    const exp = parseExpiry(text)
    return exp !== null && exp < now
  }
  const [vpcs, tunnels, rules] = await Promise.all([api.listVpcs(slugPrefix), api.listTunnels(slugPrefix), api.listAllRules()])
  const liveTeams = new Set(vpcs.filter((v) => v.slug?.startsWith(slugPrefix) && !expired(v.displayName)).map((v) => v.slug!.slice(slugPrefix.length)))
  const outcomes: Array<ActionOutcome> = []
  const run = async (action: ActionOutcome["action"], fn: () => Promise<void>) => {
    const t = Date.now()
    try {
      await fn()
      outcomes.push({ action, ok: true, ms: Date.now() - t })
    } catch (e) {
      const err = e instanceof FreestyleError ? { status: e.status, code: e.code, message: e.message, indeterminate: e.indeterminate } : { status: 0, code: "exception", message: String(e), indeterminate: true }
      outcomes.push({ action, ok: false, ms: Date.now() - t, error: err })
    }
  }
  for (const t of tunnels) {
    if (!t.slug?.startsWith(slugPrefix) || !expired(t.displayName)) continue
    await run({ op: "tunnel.delete", tunnelId: t.tunnelId, slug: t.slug, why: `expired ${env} resource` }, () => api.deleteTunnel(t.tunnelId))
  }
  for (const r of rules) {
    if (!r.description.startsWith(rulePrefix) || !expired(r.description)) continue
    const team = /team=([0-9a-f]{12}) /.exec(r.description)?.[1]
    if (team && liveTeams.has(team)) continue
    await run({ op: "rule.delete", ruleId: r.id, why: `expired ${env} resource` }, () => api.deleteRule(r.id))
  }
  for (const v of vpcs) {
    if (!v.slug?.startsWith(slugPrefix) || !expired(v.displayName)) continue
    // A VPC with machines still attached refuses deletion (409); the next run retries.
    await run({ op: "vpc.delete", vpcId: v.id }, () => api.deleteVpc(v.id))
  }
  return outcomes
}
