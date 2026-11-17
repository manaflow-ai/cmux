import type { OwnerFrame, Principal, RowReader } from "@cmux/ownership"
import { cloudSessionOf } from "./domains/team-cloud-sessions.ts"
import type { ReadResult } from "./owner-do.ts"
import { platformCloud } from "./platform-cloud.ts"

/**
 * The first publish of a Cloud session (team.cloud.session.publish with no record yet) makes the
 * publisher its owner and assignee, so TeamDO first asks the machine's owner of record whether the
 * publisher made that machine: cmux-platform's CloudDO (`cloud.machine.get`, read as the caller),
 * whose machine record names its `creator`. That is the record every other machine check reads
 * (chief-default-hand.ts, cloud-vm-receiver-peers.ts, the link_token owner kind); TeamDO keeps no
 * machine table of its own. A machine the caller cannot read (unknown to the team, deleted, or
 * another member's private machine) or one someone else created is refused with
 * cloud_session.not_yours; CloudDO unreachable is a retryable owner.unreachable.
 *
 * A machine's own install (kind `vm`) never reaches this: it may call only cloud.vm.* ops
 * (machine-installs.ts). A later publish of an existing record is the reducer's owner-or-assignee
 * check, so an assignee who never made the machine keeps publishing it.
 */
export type CloudMachineRead = (team: string, principal: Principal, machine: string) => Promise<ReadResult>

export const cloudMachineReader = (ns: DurableObjectNamespace | undefined): CloudMachineRead => (team, principal, machine) =>
  platformCloud(ns, team).readOp(team, principal, "cloud.machine.get", { machine })

/** Why a first publish is refused, or null when the caller created the machine. */
export const publishMachineRefusal = (user: string, read: ReadResult): { code: string; message: string; retryable: boolean } | null => {
  if (read.ok) {
    const creator = (read.value as { creator?: unknown } | null)?.creator
    return creator === user ? null : { code: "cloud_session.not_yours", message: "only the machine's creator publishes its Cloud sessions to the team", retryable: false }
  }
  if (read.code === "owner.unreachable") return { code: "owner.unreachable", message: "the machine's record could not be read; try again", retryable: true }
  return { code: "cloud_session.not_yours", message: "that machine is not yours in this team", retryable: false }
}

/**
 * The refusal frames for a first publish of a session on a machine the caller did not create, or
 * undefined to let the op through (a record exists, the params or principal are the reducer's to
 * refuse, or the caller made the machine).
 */
export const publishOwnershipRefusal = async (
  d: { stream: string; rows: RowReader | undefined; read: CloudMachineRead },
  entity: string,
  principal: Principal,
  frame: { readonly params?: unknown; readonly idempotency_key?: unknown }
): Promise<Array<OwnerFrame> | undefined> => {
  const p = frame.params as { vm?: unknown; session?: unknown } | null | undefined
  const user = principal.user
  if (!user || typeof p?.vm !== "string" || typeof p.session !== "string") return undefined
  if (cloudSessionOf(d.rows, p.vm, p.session)) return undefined
  const r = await d.read(entity, principal, p.vm).catch((e: unknown): ReadResult => ({ ok: false, code: "owner.unreachable", message: String(e) }))
  const refused = publishMachineRefusal(user, r)
  if (!refused) return undefined
  const key = typeof frame.idempotency_key === "string" ? frame.idempotency_key : ""
  return [
    { t: "reject", tx: "", idempotency_key: key, code: refused.code, message: refused.message, retryable: refused.retryable, replayed: false },
    { t: "request-settled", tx: "", idempotency_key: key, stream: d.stream, sequence: 0, ok: false }
  ]
}
