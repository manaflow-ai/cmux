import { RpcTarget } from "cloudflare:workers"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { AUTOMATION_OP_CLASSES, automationCapabilityOps, cloudOpByName } from "@cmux/protocol"
import { Schema } from "effect"
import type { Env } from "./env.ts"

/**
 * Capabilities of automation code (automations plan slice 4): `env.cmux` in Tier 1 code and
 * the `op` step type. An automation acts as itself: an `agent` principal built here, never
 * from a request, with the automation as identity, its team, and the op classes
 * AUTOMATION_OP_CLASSES. No token or credential reaches tenant code: CmuxCaps is an
 * RpcTarget whose claims live in private fields of the API Worker's isolate.
 */
export interface CapabilityClaims {
  readonly team: string
  readonly run: string
  readonly automation: string
}

export type CapabilityResult = { ok: true; value: unknown } | { ok: false; code: string; message: string }

const ALLOWED: ReadonlySet<string> = new Set(automationCapabilityOps)

export const automationPrincipal = (c: CapabilityClaims): Principal => ({
  kind: "agent",
  identity: `automation:${c.automation}`,
  agent: c.automation,
  run: c.run,
  team: c.team,
  grant_classes: [...AUTOMATION_OP_CLASSES]
})

interface OwnerStub {
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string }): Promise<{ frames: ReadonlyArray<OwnerFrame> }>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
}

const ownerStub = (env: Env, owner: string, team: string): OwnerStub | undefined => {
  if (owner === "cloud:SchedulerDO") return env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(team)) as unknown as OwnerStub
  if (owner === "cloud:UsageMeterDO") return env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(team)) as unknown as OwnerStub
  return undefined
}

/**
 * Runs one capability op as the automation. `key` is the idempotency key of a mutation
 * (the caller derives it from the run, so a replayed or retried step replays the op).
 */
export const callCapability = async (env: Env, claims: CapabilityClaims, name: string, params: unknown, key: string): Promise<CapabilityResult> => {
  const def = ALLOWED.has(name) ? cloudOpByName.get(name) : undefined
  if (!def) return { ok: false, code: "capability.denied", message: `${String(name).slice(0, 80)} is not an automation capability` }
  const decoded = Schema.decodeUnknownExit(def.params as Schema.Codec<unknown>)(params ?? {})
  if (decoded._tag === "Failure") return { ok: false, code: "validation.invalid", message: `invalid params for ${name}` }
  const stub = ownerStub(env, def.owner, claims.team)
  if (!stub) return { ok: false, code: "capability.denied", message: `${name} has no automation route` }
  const principal = automationPrincipal(claims)
  if (def.class === "read") {
    const r = await stub.readOp(claims.team, principal, name, decoded.value)
    return r.ok ? { ok: true, value: r.value } : { ok: false, code: r.code, message: r.message }
  }
  const res = await stub.submit(claims.team, principal, { t: "op", op: name, params: decoded.value, idempotency_key: key, origin: "script" })
  const reply = res.frames.find((f) => f.t === "result" || f.t === "reject")
  if (!reply) return { ok: false, code: "owner.unreachable", message: "no reply from the owner" }
  if (reply.t === "reject") return { ok: false, code: reply.code, message: reply.message }
  return { ok: true, value: (reply as { value?: unknown }).value }
}

/** log and metric lines per invocation (review P3: unmetered work in the API Worker). */
const MAX_LINES = 1_000
const LEVELS: ReadonlySet<string> = new Set(["debug", "info", "warn", "error"])
/** Bounded text: strings are sliced; objects are stringified only when small (shallow, 50 keys). */
const text = (v: unknown, max: number): string => {
  if (typeof v === "string") return v.slice(0, max)
  if (v === null || typeof v !== "object") return String(v).slice(0, max)
  const keys = Object.keys(v).slice(0, 50)
  return JSON.stringify(Object.fromEntries(keys.map((k) => [k.slice(0, 100), typeof (v as Record<string, unknown>)[k] === "string" ? ((v as Record<string, string>)[k]!).slice(0, 500) : typeof (v as Record<string, unknown>)[k] === "number" || typeof (v as Record<string, unknown>)[k] === "boolean" ? (v as Record<string, unknown>)[k] : "[object]"]))).slice(0, max)
}

/** A refusal tenant code sees as a thrown error with a stable code. */
export class CapabilityError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(`${code}: ${message}`)
  }
}

/**
 * `env.cmux` for one run of tenant code. State is `#` private (TypeScript `private` would
 * still be callable over RPC). Calls are refused after `close()` (the run's invocation
 * ended), so a stub kept by tenant code cannot act later.
 */
export class CmuxCaps extends RpcTarget {
  readonly #env: Env
  readonly #claims: CapabilityClaims
  readonly #journal: (key: string, fn: () => Promise<unknown>) => Promise<unknown>
  #closed = false
  #lines = 0

  constructor(env: Env, claims: CapabilityClaims, journal: (key: string, fn: () => Promise<unknown>) => Promise<unknown>) {
    super()
    this.#env = env
    this.#claims = claims
    this.#journal = journal
  }

  close(): void {
    this.#closed = true
  }

  /**
   * One capability op. A mutation needs `options.idempotency_key` (1 to 100 of [A-Za-z0-9._:-],
   * unique within the run): a Workflow replay or a step retry repeats the call with the same key
   * and the owner answers from its ledger, so the effect happens once. Reads need no key.
   */
  async op(name: unknown, params: unknown, options?: unknown): Promise<unknown> {
    if (this.#closed) throw new CapabilityError("capability.closed", "this run's capabilities are closed")
    const op = String(name)
    const given = (options as { idempotency_key?: unknown } | null | undefined)?.idempotency_key
    const custom = typeof given === "string" && /^[A-Za-z0-9._:-]{1,100}$/.test(given) ? given : undefined
    if (cloudOpByName.get(op)?.class === "mutation" && !custom) {
      throw new CapabilityError("validation.invalid", `${op.slice(0, 80)} changes state: pass { idempotency_key } (1 to 100 of A-Z a-z 0-9 . _ : -, unique in the run)`)
    }
    const call = async () => {
      const r = await callCapability(this.#env, this.#claims, op, params, `cap:${this.#claims.run}:${custom ?? "read"}`)
      // Temporary refusals throw inside the journaled step, so the engine retries them.
      if (!r.ok && (r.code === "owner.unreachable" || r.code === "rate.limited" || r.code === "policy.pending")) throw new Error(`${r.code}: ${r.message}`)
      return r
    }
    // A mutation is its own durable step (WrappedStep journal); a read just runs.
    const r = (custom && cloudOpByName.get(op)?.class === "mutation" ? await this.#journal(custom, call) : await call()) as CapabilityResult
    if (!r.ok) throw new CapabilityError(r.code, r.message)
    return r.value
  }

  async log(level: unknown, msg: unknown, attrs?: unknown): Promise<void> {
    if (this.#closed || ++this.#lines > MAX_LINES) return
    const c = this.#claims
    console.log(JSON.stringify({ source: "automation", team: c.team, run: c.run, automation: c.automation, level: LEVELS.has(String(level)) ? String(level) : "info", msg: text(msg, 2_000), attrs: text(attrs ?? {}, 4_000) }))
  }

  async metric(name: unknown, value: unknown, attrs?: unknown): Promise<void> {
    if (this.#closed || ++this.#lines > MAX_LINES || typeof value !== "number" || !Number.isFinite(value)) return
    const c = this.#claims
    console.log(JSON.stringify({ source: "automation.metric", team: c.team, run: c.run, automation: c.automation, name: text(name, 100), value, attrs: text(attrs ?? {}, 1_000) }))
  }
}
