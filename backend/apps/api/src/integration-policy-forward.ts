import type { Principal } from "@cmux/ownership"
import { integrationSlice } from "./domains/team-policy.ts"

/**
 * Enterprise F3 / P17-6: `integration.policy.set` forwards to `team.policy.update` for one
 * release, so TeamPolicy stays the single writer of the integration policy (TeamDO then pushes
 * its integration slice to ConnectionDO as before). The Worker translates the old fields into
 * policy keys and submits them with the caller's own principal, so TeamDO's admin check applies
 * (a system forward would skip it). Values are set as enforced, like an admin edit was.
 */
export interface PolicyFields {
  readonly allowed_providers?: ReadonlyArray<string> | null
  readonly github?: { readonly scope?: string; readonly require_org_admin?: boolean; readonly repo_allowlist?: ReadonlyArray<string> | null }
}

type Change = { key: string; value: { value: unknown; mode: "enforced" } }
const set = (key: string, value: unknown): Change => ({ key, value: { value, mode: "enforced" } })

/** The team.policy.update changes for old integration.policy.set fields (the inverse of integrationSlice). */
export const integrationChanges = (f: PolicyFields): Array<Change> => {
  const out: Array<Change> = []
  if (f.allowed_providers !== undefined) out.push(set("integrations.allowedProviders", f.allowed_providers === null ? "all" : [...f.allowed_providers]))
  const g = f.github
  if (g?.scope !== undefined) out.push(set("github.repoScope", g.scope))
  if (g?.require_org_admin !== undefined) out.push(set("github.requireOrgAdmin", g.require_org_admin))
  // [] in the old shape denies every repository ("none"); null means no limit (an empty list).
  if (g?.repo_allowlist !== undefined) out.push(set("github.repoAllowList", g.repo_allowlist === null ? [] : g.repo_allowlist.length === 0 ? "none" : [...g.repo_allowlist]))
  return out
}

interface TeamStub {
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { policy?: { version?: number } } }>
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string }): Promise<{ frames: Array<{ t: string }> }>
}

interface ConnectionStub {
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { source?: string; locked?: boolean } }>
}

const reject = (key: string, code: string, message: string) => ({ frames: [{ t: "reject", tx: "", idempotency_key: key, code, message, retryable: false, replayed: false }] })

/**
 * Runs the forward. An SSO or MDM lock on ConnectionDO still wins (policy.locked, as before);
 * otherwise team.policy.update commits at the current version and the result is answered in the
 * old shape (the team's integration slice, source team_policy). ConnectionDO receives it through
 * TeamDO's push within seconds.
 */
export const forwardIntegrationPolicy = async (team: TeamStub, connections: ConnectionStub, entity: string, principal: Principal, fields: PolicyFields, idempotencyKey: string) => {
  const changes = integrationChanges(fields)
  if (changes.length === 0) return reject(idempotencyKey, "validation.invalid", "no policy fields to change")
  const held = await connections.readOp(entity, principal, "integration.policy.get", {})
  if (held.ok && held.value?.locked && (held.value.source === "sso" || held.value.source === "mdm")) return reject(idempotencyKey, "policy.locked", `the policy is managed by ${held.value.source} and cannot be changed here`)
  const current = await team.readOp(entity, principal, "team.policy.get", {})
  const version = current.ok ? (current.value?.policy?.version ?? 0) : 0
  const res = await team.submit(entity, principal, { t: "op", op: "team.policy.update", params: { changes, expected_version: version, reason: "integration.policy.set (deprecated alias)" }, idempotency_key: idempotencyKey, origin: "user" })
  return {
    frames: res.frames.map((f) => {
      if (f.t !== "result") return f
      const policy = (f as unknown as { value: { values: Record<string, unknown>; updated_at: number | null; updated_by: string | null } }).value
      return { ...f, value: { ...integrationSlice(policy.values as never), source: "team_policy", locked: true, updated_at: policy.updated_at, updated_by: policy.updated_by } }
    })
  }
}
