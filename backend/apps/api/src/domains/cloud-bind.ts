import type { ReduceContext, ReduceResult, RowReader, RowWrite } from "@cmux/ownership"
import { CloudMachineBindParams } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { reject } from "./common.ts"
import { TABLE_MACHINE, type CloudState, type MachineRow } from "./cloud.ts"

/** The bind token expires this long after the provider reported the VM running (5.8 item 1). */
export const BIND_TOKEN_TTL_MS = 15 * 60_000

/** One-time bind state of a machine; only the token's sha256 is ever stored. */
export interface BindState {
  readonly token_sha256: string
  readonly expires_at: number
  readonly spent: boolean
}

/**
 * `cloud.machine.bind` (5.8 item 2): the VM's bind agent spends the one-time token. Any token
 * problem (unknown machine, wrong token, spent, expired, no token yet) is one auth.forbidden, so a
 * caller learns nothing about which. A restore or re-bind will raise `epoch` and need a fresh token;
 * today a second bind is refused because the token is spent.
 */
export const bindMachine = (state: CloudState, params: unknown, ctx: ReduceContext, next: (s: CloudState, patch: Partial<CloudState>, changed: CloudState["changed"]) => CloudState): ReduceResult<CloudState> => {
  const exit = Schema.decodeUnknownExit(CloudMachineBindParams as Schema.Codec<typeof CloudMachineBindParams.Type, unknown>)(params ?? {})
  if (!Exit.isSuccess(exit)) return reject("validation.invalid", "invalid bind")
  const p = exit.value
  const stored = (ctx.rows as RowReader | undefined)?.get<MachineRow>(TABLE_MACHINE, p.machine)
  const m = stored?.row
  const refused = reject("auth.forbidden", "bind refused")
  if (!stored || !m || !m.bind || !m.host_id) return refused
  if (m.bind.spent || m.bind.token_sha256 !== p.token_sha256 || p.now > m.bind.expires_at) return refused
  if (m.status === "deleting" || m.status === "failed") return refused
  const rev = state.rev + 1
  const row: MachineRow = {
    ...m,
    host: m.host_id,
    status: "running",
    image: { ...m.image, daemon_version: p.daemon.version },
    bind: { ...m.bind, spent: true },
    wg_public_key: p.wg_public_key,
    daemon: { version: p.daemon.version, capabilities: [...p.daemon.capabilities] },
    keyset_version: p.keyset_version,
    vm_install: p.vm_install,
    revision: String(rev)
  }
  const writes: Array<RowWrite> = [{ table: TABLE_MACHINE, op: "upsert", key: row.id, n: stored.n, row }]
  return { ok: true, state: next(state, {}, { machine: row.id, removed: false }), value: { machine: row.id, host: row.host, epoch: row.epoch ?? 1 }, writes }
}
