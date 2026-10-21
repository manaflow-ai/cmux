import type { OwnerFrame, Principal, RowReader, SqlStore } from "@cmux/ownership"
import { who, type AccessAudit } from "./cloud-connect.ts"
import { TABLE_MACHINE, type MachineRow } from "./domains/cloud.ts"
import type { VmInstallRevokes } from "./cloud-vm-revoke.ts"
import { VmReceiverGenerations } from "./cloud-vm-receiver-generations.ts"

/** Machine commits retire grants and receiving attempts through one owner path. */
export class CloudMachineAuthorities {
  constructor(private readonly sql: SqlStore, private readonly revokes: VmInstallRevokes,
    private readonly audit: () => AccessAudit, private readonly now: () => number,
    private readonly retry: { at(machine: string): number | null; clear(machine: string): void }) {}

  afterOp(rows: RowReader, changed: string | undefined, principal: Principal, op: string, frames: ReadonlyArray<OwnerFrame>): void {
    const value = (frames.find((f) => f.t === "result") as { value?: { audit?: { machine?: unknown } } } | undefined)?.value
    const machines = new Set([changed, op === "cloud.abandoned_clear" ? value?.audit?.machine : undefined].filter((m): m is string => typeof m === "string"))
    for (const machine of machines) {
      const row = rows.get<MachineRow>(TABLE_MACHINE, machine)?.row
      this.revokes.reconcile(machine, row, this.now())
      this.closeReceiver(machine, row, principal, op)
      const status = row?.status
      if (status !== "running" && status !== "provisioning" && status !== "pausing" && this.retry.at(machine) !== null) this.retry.clear(machine)
    }
  }

  /** Repair a crash between committing a power intent and retiring its receiver.
   * This runs before tenant resolution or any other provider I/O.
   */
  beforeProvider(rows: RowReader, machine: string): void {
    this.closeReceiver(machine, rows.get<MachineRow>(TABLE_MACHINE, machine)?.row,
      { identity: "system:cloud-provider", kind: "system" }, "cloud.provider_retry")
  }

  private closeReceiver(machine: string, row: MachineRow | undefined, principal: Principal, trigger: string): void {
    if (row?.transport === "vm-api" && row.status === "running") return
    const audit = this.audit()
    new VmReceiverGenerations(this.sql).close(machine, (entry) => audit.record({ op: "vm_receiver_lifecycle", ...entry,
      ...who(principal), trigger, cause: "machine_lifecycle", at: this.now() }))
  }
}
