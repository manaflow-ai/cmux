import { type components, type createCmuxVmClient } from "@cmux/vm"
import { DriverError } from "./team-vm-driver.ts"
import type { VmTag } from "./cloud-driver.ts"

type Client = ReturnType<typeof createCmuxVmClient>
type Capture = components["schemas"]["SnapshotCreationStatus"]
const SNAPSHOT = /^snap_[0-9a-hjkmnp-tv-z]{26}$/
const VM = /^vm_[0-9a-hjkmnp-tv-z]{26}$/

/** Only a verified terminal receipt can release Cloud's saved quota after an uncertain capture. */
export class VmApiSnapshotOutcome extends DriverError {
  constructor(readonly outcome: "pending" | "deleted" | "absent", message = "snapshot capture is still being confirmed", code = "cloud.provider.unavailable") {
    super(code, outcome === "absent" ? message : `VM API: ${message}`, outcome !== "pending")
  }
}

/** The VM service owns capture durability; Cloud resumes its stable key instead of duplicating that journal. */
export class VmApiSnapshotCaptures {
  constructor(private readonly client: Client, private readonly team: string,
    private readonly lookupOwned: (name: string, expected: { machine?: string; source?: string }) => Promise<{ id: string } | null>) {}

  private async request<R>(work: () => Promise<R>): Promise<R> {
    try { return await work() } catch { throw new VmApiSnapshotOutcome("pending") }
  }
  private validate(value: Capture | undefined, name: string, expected: { machine?: string; source?: string | null }, id?: string, allowMissingSource = false): Capture {
    const receipt = value?.receipt, source = receipt?.sourceVmId
    const validSource = (allowMissingSource && source === null) || (typeof source === "string" && VM.test(source))
    if (!value || !receipt || !SNAPSHOT.test(value.id) || receipt.id !== value.id || (id !== undefined && value.id !== id)
      || !validSource || (expected.source !== undefined && source !== expected.source)
      || receipt.displayName !== name || receipt.labels?.role !== "cloud" || receipt.labels.cmux_next_team !== this.team
      || receipt.labels["cmux/name"] !== name || !receipt.labels.cmux_next_machine
      || (expected.machine !== undefined && receipt.labels.cmux_next_machine !== expected.machine)
      || (value.retryCreate !== undefined && typeof value.retryCreate !== "boolean")
      || !["pending", "committed", "deleted"].includes(value.state)
      || (value.cancellation !== undefined && value.cancellation !== "requested" && value.cancellation !== "completed")) {
      throw new VmApiSnapshotOutcome("pending", "unconfirmed snapshot capture")
    }
    return value
  }
  private completed(value: Capture): { id: string } | null {
    if (value.state === "deleted") throw new VmApiSnapshotOutcome("deleted", "snapshot capture was deleted")
    return value.state === "committed" && value.cancellation === undefined ? { id: value.id } : null
  }

  async resume(name: string, expected: { machine?: string; source?: string }, allowSend: boolean): Promise<{ id: string } | null> {
    const found = await this.request(() => this.client.GET("/v1/snapshot-creations/by-key", { params: { header: { "idempotency-key": `cloud-snapshot:${name}` } } }))
    if (found.response.status === 404) {
      // A legacy key may have expired while its canonical snapshot still exists.
      const owned = await this.request(() => this.lookupOwned(name, expected))
      if (owned) return { id: owned.id }
      // Refuse fresh captures against a Worker predating durable capture support.
      const support = await this.request(() => this.client.GET("/v1/snapshot-creations", { params: { query: { limit: "1" } } }))
      if (support.response.status !== 200 || !Array.isArray(support.data?.items) || !(support.data?.nextCursor === null || typeof support.data?.nextCursor === "string"))
        throw new VmApiSnapshotOutcome("pending", "durable snapshot capture support is unavailable")
      return null
    }
    if (found.response.status !== 200) throw new VmApiSnapshotOutcome("pending")
    const original = this.validate(found.data, name, expected)
    const done = this.completed(original)
    if (done) return done
    const answer = await this.request(() => this.client.POST("/v1/snapshot-creations/{snapshotId}/reconcile", { params: { path: { snapshotId: original.id } } }))
    if (answer.response.status !== 200) throw new VmApiSnapshotOutcome("pending")
    const current = this.validate(answer.data, name, { ...expected, source: original.receipt.sourceVmId! }, original.id)
    const recovered = this.completed(current)
    if (recovered) return recovered
    // A claim that failed billing/quota before dispatch still needs its original create resumed.
    // The VM service's permanent key and send gate forbid recapturing an uncertain outcome.
    if (allowSend && current.retryCreate === true && current.cancellation === undefined) return this.create(current.receipt.sourceVmId!, name, current.receipt.labels, original.id)
    throw new VmApiSnapshotOutcome("pending")
  }

  async create(source: string, name: string, labels: Record<string, string>, id?: string): Promise<{ id: string }> {
    const answer = await this.request(() => this.client.POST("/v1/vms/{vmId}/snapshots", {
      params: { path: { vmId: source }, header: { "idempotency-key": `cloud-snapshot:${name}` } }, body: { displayName: name, labels },
    }))
    if (answer.response.status !== 201) throw new VmApiSnapshotOutcome("pending")
    const capture = this.validate(answer.data === undefined ? undefined : { state: "committed", id: answer.data.id, receipt: answer.data }, name,
      { source, ...(labels.cmux_next_machine === undefined ? {} : { machine: labels.cmux_next_machine }) }, id)
    return { id: capture.id }
  }

  async cancel(name: string, tag: VmTag, allowEmptyFence: boolean): Promise<void> {
    if (tag.team !== this.team) throw new DriverError("cloud.provider.name_conflict", "VM API: wrong Cloud team", true)
    const found = await this.request(() => this.client.GET("/v1/snapshot-creations/by-key", { params: { header: { "idempotency-key": `cloud-snapshot:${name}` } } }))
    const original = found.response.status === 200 ? this.validate(found.data, name, { machine: tag.machine }, undefined, true) : undefined
    if (original === undefined && found.response.status !== 404 && found.response.status !== 409) throw new VmApiSnapshotOutcome("pending")
    const answer = await this.request(() => this.client.POST("/v1/snapshot-creations/by-key/cancel", {
      params: { header: { "idempotency-key": `cloud-snapshot:${name}` } }, body: { expectedSnapshotId: original?.id ?? null },
    }))
    const result = answer.data
    if (answer.response.status !== 200 || !result) throw new VmApiSnapshotOutcome("pending")
    if (result.state === "fenced" && result.id === null && result.receipt === undefined) {
      const owned = await this.request(() => this.lookupOwned(name, { machine: tag.machine }))
      if (owned) {
        const deleted = await this.request(() => this.client.DELETE("/v1/snapshots/{snapshotId}", { params: { path: { snapshotId: owned.id } } }))
        if (deleted.response.status !== 204 && deleted.response.status !== 404) throw new VmApiSnapshotOutcome("pending")
        return
      }
      if (!allowEmptyFence) throw new VmApiSnapshotOutcome("pending", "legacy capture outcome still needs reconciliation")
      return
    }
    if (!original || !result.receipt || result.id === null || (result.state !== "cancelled" && result.state !== "cancelling")) throw new VmApiSnapshotOutcome("pending", "unconfirmed capture cancellation")
    this.validate({ id: result.id, state: result.state === "cancelled" ? "deleted" : "pending", receipt: result.receipt },
      name, { machine: tag.machine, source: original.receipt.sourceVmId }, original.id, true)
    if (result.state !== "cancelled") throw new VmApiSnapshotOutcome("pending")
  }

  async resumeFor(tag: VmTag, name: string, allowSend: boolean): Promise<{ id: string } | null> {
    if (tag.team !== this.team) throw new DriverError("cloud.provider.name_conflict", "VM API: wrong Cloud team", true)
    return this.resume(name, { machine: tag.machine }, allowSend)
  }
}
