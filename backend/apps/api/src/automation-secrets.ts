import type { Principal } from "@cmux/ownership"
import { AUTOMATION_SECRETS_MAX, AutomationSecretRemove, AutomationSecretSet } from "@cmux/protocol"
import { decodeParams } from "./domains/common.ts"
import { refusal } from "./domains/scheduler-access.ts"
import type { Env } from "./env.ts"
import { openSecretText, sealSecretText, type CredentialAddress } from "./integrations/credentials.ts"
import type { Http } from "./integrations/provider-core.ts"
import { secretValueProblem } from "./automation-secrets-wire.ts"
import type { DomainReply } from "./team-domain-external.ts"

/**
 * Per-automation secrets (AUTOMATIONS-SPEC section 12; protocol automation-secret-ops.ts). One sealed
 * value per automation and name, in a SchedulerDO side table, written only by someone who may edit
 * the automation, in a person's session (`automation.secret.set`, `.remove`, POST /v1/ops), and opened
 * only by a running run's Workflow (SchedulerDO.runSecrets), inside the step that uses it. Sealed like
 * the team's shared agent keys (team-agent-keys.ts): a fresh data key per seal, KMS when configured,
 * else INTEGRATIONS_KEK, bound to team, automation, name and generation. A removal clears the seal and
 * keeps the row, so a later set never reuses an address. Deleting the automation deletes its rows.
 */

export interface SecretAutomation {
  readonly id: string
  readonly owner: string
  readonly created_by: string
  readonly sharing?: "team" | "private"
  readonly editors?: ReadonlyArray<string>
}

export interface SecretDeps {
  readonly team: string
  readonly stream: string
  readonly env: Env
  readonly http: Http
  readonly sql: SqlStorage
  readonly now: () => number
  readonly automation: (id: string) => SecretAutomation | undefined
}

export const ensureSecretTable = (sql: SqlStorage) =>
  sql.exec(
    `CREATE TABLE IF NOT EXISTS automation_secrets (automation TEXT NOT NULL, name TEXT NOT NULL, generation INTEGER NOT NULL, sealed TEXT, hint TEXT, updated_at INTEGER NOT NULL, updated_by TEXT NOT NULL, last_key TEXT, PRIMARY KEY (automation, name))`
  )

interface Row {
  name: string
  generation: number
  sealed: string | null
  hint: string | null
  updated_at: number
  updated_by: string
  last_key: string | null
}

const rows = (sql: SqlStorage, automation: string): Array<Row> => {
  ensureSecretTable(sql)
  return sql
    .exec<Record<string, SqlStorageValue>>(`SELECT name, generation, sealed, hint, updated_at, updated_by, last_key FROM automation_secrets WHERE automation = ? ORDER BY name`, automation)
    .toArray()
    .map((r) => ({
      name: String(r.name),
      generation: Number(r.generation),
      sealed: r.sealed === null ? null : String(r.sealed),
      hint: r.hint === null ? null : String(r.hint),
      updated_at: Number(r.updated_at),
      updated_by: String(r.updated_by),
      last_key: r.last_key === null ? null : String(r.last_key)
    }))
}

const addressOf = (team: string, automation: string, name: string, generation: number): CredentialAddress => ({ connection: `automation-secret:${automation}`, owner: team, provider: `secret:${name}`, generation })
/** The last four characters of a one-line token of at least 12 printable characters, else none. */
const hintOf = (v: string) => (v.length >= 12 && /^[\x21-\x7e]+$/.test(v) ? v.slice(-4) : null)
const stateOf = (r: Row) => ({ name: r.name, hint: r.hint, generation: r.generation, updated_at: r.updated_at, updated_by: r.updated_by })

/** `automation.secret.set` and `automation.secret.remove` (module docs). */
export const secretExternal = async (deps: SecretDeps, p: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<DomainReply> => {
  const base = { op: frame.op, transaction: "", idempotency_key: frame.idempotency_key, stream: deps.stream, sequence: 0, replayed: false }
  const fail = (code: string, message: string, retryable = false): DomainReply => ({ ...base, ok: false, error: { code, message, retryable } })
  if (p.kind !== "session" || p.agent || !p.user) return fail("auth.forbidden", "an automation's secrets are changed by a person, in their own session")
  if (p.team !== deps.team) return fail("auth.forbidden", "not a member of this team")
  const remove = frame.op === AutomationSecretRemove.name
  const d = remove
    ? decodeParams<{ automation: string; name: string }>(AutomationSecretRemove, frame.params)
    : decodeParams<{ automation: string; name: string; value: string }>(AutomationSecretSet, frame.params)
  if (!d.ok) return fail(d.code, remove ? d.message : "invalid params")
  const a = deps.automation(d.value.automation)
  const refused = refusal(p, deps.team, a, "edit")
  if (refused) return fail(refused.code, refused.message)
  const { automation, name } = d.value
  const all = rows(deps.sql, automation)
  const prior = all.find((r) => r.name === name)
  const by = p.user

  if (remove) {
    if (!prior?.sealed) return { ...base, ok: true, value: { automation, name, removed: false } }
    deps.sql.exec(
      `UPDATE automation_secrets SET sealed = NULL, hint = NULL, generation = generation + 1, updated_at = ?, updated_by = ?, last_key = NULL WHERE automation = ? AND name = ? AND generation = ?`,
      deps.now(), by, automation, name, prior.generation
    )
    return { ...base, ok: true, value: { automation, name, removed: true } }
  }

  const value = (d.value as unknown as { value: string }).value
  const problem = secretValueProblem(value)
  if (problem) return fail("validation.invalid", problem)
  // A retry of the same request (a lost answer) is answered from the row it wrote, not sealed again.
  if (prior?.sealed && prior.last_key === `${by}|${frame.idempotency_key}`) return { ...base, ok: true, replayed: true, value: stateOf(prior) }
  if (!prior?.sealed && all.filter((r) => r.sealed).length >= AUTOMATION_SECRETS_MAX) return fail("automation_secret.too_many", `an automation holds at most ${AUTOMATION_SECRETS_MAX} secrets`)
  const before = prior?.generation ?? 0
  const generation = before + 1
  let sealed: string
  try {
    sealed = JSON.stringify(await sealSecretText(deps.env, deps.http, addressOf(deps.team, automation, name, generation), value))
  } catch (e) {
    console.error(JSON.stringify({ msg: "automation secret seal failed", team: deps.team, automation, name, error: e instanceof Error ? e.name : "unknown" }))
    if (!deps.env.INTEGRATIONS_KEK && !deps.env.INTEGRATIONS_KMS_KEY_ARN) return fail("automation_secret.not_configured", "secrets are not configured on this deployment")
    return fail("owner.unreachable", "the secret could not be sealed; try again", true)
  }
  const now = deps.now()
  // Compare-and-swap across the seal's await: whoever wrote first wins; the other retries.
  const written =
    before === 0
      ? deps.sql.exec(
          `INSERT INTO automation_secrets (automation, name, generation, sealed, hint, updated_at, updated_by, last_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (automation, name) DO NOTHING`,
          automation, name, generation, sealed, hintOf(value), now, by, `${by}|${frame.idempotency_key}`
        )
      : deps.sql.exec(
          `UPDATE automation_secrets SET generation = ?, sealed = ?, hint = ?, updated_at = ?, updated_by = ?, last_key = ? WHERE automation = ? AND name = ? AND generation = ?`,
          generation, sealed, hintOf(value), now, by, `${by}|${frame.idempotency_key}`, automation, name, before
        )
  if (written.rowsWritten === 0) return fail("revision.conflict", "someone changed this secret at the same time; try again", true)
  return { ...base, ok: true, value: stateOf(rows(deps.sql, automation).find((r) => r.name === name)!) }
}

/** `automation.secret.list`: names and hints of the set secrets, for who may edit the automation. */
export const secretList = (deps: Pick<SecretDeps, "team" | "sql" | "automation">, p: Principal, automation: string) => {
  const refused = refusal(p, deps.team, deps.automation(automation), "edit")
  if (refused) return { ok: false as const, ...refused }
  const set = rows(deps.sql, automation).filter((r) => r.sealed)
  return { ok: true as const, value: { automation, secrets: set.map(stateOf) }, revision: String(set.reduce((s, r) => s + r.generation, 0)) }
}

/** The opened secrets of `automation`, for its running run's Workflow only (SchedulerDO.runSecrets). */
export const secretsOpen = async (deps: Pick<SecretDeps, "team" | "sql" | "env" | "http">, automation: string): Promise<Record<string, string>> => {
  const out: Record<string, string> = {}
  for (const r of rows(deps.sql, automation)) {
    if (r.sealed) out[r.name] = await openSecretText(deps.env, deps.http, addressOf(deps.team, automation, r.name, r.generation), r.sealed)
  }
  return out
}

/** An automation's secrets leave with it. */
export const secretsDrop = (sql: SqlStorage, automation: string) => {
  ensureSecretTable(sql)
  sql.exec(`DELETE FROM automation_secrets WHERE automation = ?`, automation)
}
