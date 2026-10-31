import type { CloudVmNetwork } from "@cmux/protocol"
import type { MachineRow } from "./domains/cloud.ts"
import { transportOf } from "./cloud-vm-api-config.ts"

/** A response from another allocation, epoch, transport or network cannot update this row. */
export const networkBinding = (row: MachineRow): string => JSON.stringify([transportOf(row), row.provider_name, row.host, row.epoch, row.status, row.network])

/** One bounded provider read per live binding; concurrent connection requests join it. */
export class CloudNetworkObservation {
  private readonly checked = new Map<string, { binding: string; at: number }>()
  private readonly pending = new Map<string, { binding: string; work: Promise<boolean> }>()
  constructor(private readonly now: () => number,
              private readonly row: (entity: string, id: string) => MachineRow | undefined,
              private readonly read: (row: MachineRow) => Promise<typeof CloudVmNetwork.Type>,
              private readonly publish: (row: MachineRow, binding: string, network: typeof CloudVmNetwork.Type) => boolean) {}

  async check(entity: string, row: MachineRow): Promise<boolean> {
    if (transportOf(row) !== "vm-api" || row.status !== "running") return true
    if (!row.network) return false
    const binding = networkBinding(row), cached = this.checked.get(row.id)
    if (cached?.binding === binding && this.now() - cached.at < 30_000) return true
    const pending = this.pending.get(row.id)
    if (pending?.binding === binding) return pending.work
    const work = this.refresh(entity, row, binding)
    const item = { binding, work }; this.pending.set(row.id, item)
    try { return await work } finally { if (this.pending.get(row.id) === item) this.pending.delete(row.id) }
  }

  private async refresh(entity: string, row: MachineRow, binding: string): Promise<boolean> {
    try {
      const network = await this.read(row)
      const current = this.row(entity, row.id)
      if (!current || networkBinding(current) !== binding) return false
      if (JSON.stringify(network) !== JSON.stringify(current.network) && !this.publish(current, binding, network)) return false
      const updated = this.row(entity, row.id)
      if (!updated || updated.status !== "running") return false
      this.checked.set(row.id, { binding: networkBinding(updated), at: this.now() })
      return true
    } catch { return false }
  }
}
