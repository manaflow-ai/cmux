import { Schema } from "effect"
import type { CloudOpDef } from "./op-def.ts"
import { InstallId } from "./schemas.ts"

/**
 * Ops only CloudDO itself submits (plans/cmux-next/state-placement.md 5.2). Not exported to the
 * catalog: no HTTP, MCP or CLI surface.
 */
export const CloudDriverResultParams = Schema.Struct({
  /** The provider-call ledger row (one per intent, keyed by the op's idempotency key). */
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  ok: Schema.Boolean,
  /** create: the provider's VM id. */
  provider_id: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.Struct({ code: Schema.String, message: Schema.String })),
  /** Retrying cannot help (configuration, authorization, a name owned by someone else). */
  final: Schema.optionalKey(Schema.Boolean),
  /** create: sha256 (hex) of the one-time bind token written into the VM; the token itself never enters an op. */
  bind_token_sha256: Schema.optionalKey(Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)))
})

/**
 * The VM's bind agent bound the machine (state-placement.md 5.8 item 2). CloudDO hashes the bind
 * token before the op, so neither the token nor its plaintext enters params, events or the ledger.
 */
export const CloudMachineBindParams = Schema.Struct({
  machine: Schema.String.check(Schema.isPattern(/^vm_[a-z0-9]{20}$/)),
  token_sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
  wg_public_key: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9+/]{43}=$/)),
  daemon: Schema.Struct({
    version: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64)),
    capabilities: Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64))).check(Schema.isMaxLength(32))
  }),
  /** The link-token keyset version handed to the VM in the bind answer. */
  keyset_version: Schema.String.check(Schema.isMaxLength(64)),
  /** The VM install the server registered with the bind request's install_public_jwk. */
  vm_install: InstallId,
  now: Schema.Int
})

/** One applied cloud.vm.status.report (coalesced by CloudDO to at most 1 per 10 s per machine). */
export const CloudVmStatusParams = Schema.Struct({
  machine: Schema.String.check(Schema.isPattern(/^vm_[a-z0-9]{20}$/)),
  report: Schema.Unknown,
  now: Schema.Int
})

export const CloudPruneParams = Schema.Struct({ now: Schema.Int })

/** An operator cleared one abandoned ledger row after checking the provider by hand (who, when, why). */
export const CloudAbandonedClearParams = Schema.Struct({
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  by: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128)),
  by_email: Schema.NullOr(Schema.String.check(Schema.isMaxLength(320))),
  reason: Schema.String.check(Schema.isMinLength(8), Schema.isMaxLength(500)),
  at: Schema.Int
})

/** One hourly lookup of a cancelled create's recorded name (N1): absent, deleted by that name, or a VM whose metadata does not match. */
export const CloudWatchResultParams = Schema.Struct({
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  outcome: Schema.Literals(["absent", "deleted", "mismatch"]),
  now: Schema.Int
})

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:CloudDO",
    class: "mutation",
    risk: "mutate-own",
    target: "team",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

export const cloudInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("cloud.driver_result", CloudDriverResultParams, "Internal: a provider call (create or delete) finished, failed, or was refused."),
  internal("cloud.watch_result", CloudWatchResultParams, "Internal: one lookup of a cancelled create's recorded name finished."),
  internal("cloud.machine.bind", CloudMachineBindParams, "Internal: the VM's bind agent spent its one-time bind token (POST /v1/cloud/bind)."),
  internal("cloud.machine.idle_pause", Schema.Struct({ machine: Schema.String.check(Schema.isPattern(/^vm_[a-z0-9]{20}$/)) }), "Internal: CloudDO pauses a machine its own activity report showed idle past its idle policy (team policy cloud.idlePause on); the same ledger and provider path as cloud.machine.pause."),
  internal("cloud.machine.vm_status", CloudVmStatusParams, "Internal: CloudDO applies the VM's latest coalesced status report (state, daemon, activity)."),
  internal("cloud.prune", CloudPruneParams, "Internal: drop tombstones older than 30 days and finished ledger rows older than 7 days."),
  internal("cloud.abandoned_clear", CloudAbandonedClearParams, "Internal: an operator (a person, with the admin key) cleared one abandoned ledger row after a provider lookup found no VM; audited.")
]
