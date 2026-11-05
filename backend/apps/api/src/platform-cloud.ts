import type { Principal } from "@cmux/ownership"
import type { MachineExecReply } from "./automation-machine.ts"
import type { ReadResult, SubmitResult } from "./owner-do.ts"

/**
 * The typed client of cmux-platform's CloudDO. NEXT Cloud's machine record lives in cmux-platform; this Worker's
 * CLOUD_DO binding names that class (`script_name: cmux-platform-<env>` in wrangler.jsonc), and these are the
 * only RPCs this Worker calls on it. The class, its drivers and its routes are not in this Worker.
 */
export type CloudReply = { ok: true; value: unknown } | { ok: false; code: string; message: string; details?: unknown }

export interface PlatformCloud {
  /** An op of the Cloud catalog (cloud.*), as every owner takes it. */
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string; expected_revision?: string }): Promise<SubmitResult>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult>
  /** `cloud.link_token`: a link token for one of the caller's machines (never keyed, never replayed). */
  mintLinkToken(entity: string, principal: Principal, params: unknown, request: string): Promise<CloudReply>
  /** A VM install's own-machine ops (cloud.vm.*). */
  vmOp(entity: string, principal: Principal, op: string, params: unknown): Promise<CloudReply>
  /** A command on one of the team's machines for an automation run or a Chief hand. */
  automationExec(entity: string, user: string | null, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply>
  /** Operator: clear a machine whose provider VM is gone (cloud-admin.ts). */
  clearAbandoned(entity: string, machine: string, who: { user: string; email: string | null }, reason: string): Promise<{ ok: boolean; code?: string; message?: string; audit?: unknown }>
}

/** The platform's CloudDO for one team. */
export const platformCloud = (ns: DurableObjectNamespace, team: string): PlatformCloud => ns.get(ns.idFromName(team)) as unknown as PlatformCloud
