/**
 * Provider-neutral machine contract for cmux NEXT Cloud.
 *
 * The API layer owns identity, idempotency and usage receipts; a provider only
 * supplies machine lifecycle and pricing. Freestyle and GCP can implement this
 * contract without leaking provider handles into CloudDO state.
 */

export type MachineState = "running" | "stopped"
export type MachineOperation = "allocate" | "start" | "stop" | "snapshot" | "fork" | "idle_stop"

export interface MachineShape {
  readonly cpu: number
  readonly memoryMb: number
  readonly diskGb: number
}

export interface MachineRequest {
  readonly owner: string
  readonly idempotencyKey: string
  readonly region: string
  readonly shape: MachineShape
  readonly image: string
  readonly idleTimeoutSeconds: number
}

export interface MachineRef {
  readonly id: string
  readonly owner: string
  readonly generation: number
}

export interface CostEstimate {
  readonly currency: "USD"
  /** Provider list rates, before plan credits or any cmux margin. */
  readonly runningUsdMicrosPerHour: number
  readonly storageUsdMicrosPerGbMonth: number
  readonly egressUsdMicrosPerGb: number
  readonly source: string
  readonly measuredAt: string
}

export interface UsageReceipt {
  readonly machine: MachineRef
  readonly from: string
  readonly to: string
  readonly runningSeconds: number
  readonly amountUsdMicros: number
  readonly estimate: CostEstimate
}

export interface ProviderReceipt<T extends MachineOperation> {
  readonly operation: T
  readonly provider: string
  readonly idempotencyKey: string
  readonly machine: MachineRef
  readonly state: MachineState
  readonly occurredAt: string
  readonly details?: Readonly<Record<string, string>>
}

export interface MachineSnapshot {
  readonly id: string
  readonly source: MachineRef
  readonly createdAt: string
}

export interface MachineProvider {
  readonly name: string
  allocate(request: MachineRequest): Promise<ProviderReceipt<"allocate">>
  start(machine: MachineRef, idempotencyKey: string): Promise<ProviderReceipt<"start">>
  stop(machine: MachineRef, idempotencyKey: string): Promise<ProviderReceipt<"stop">>
  idleStop(machine: MachineRef, idempotencyKey: string, lastActivityAt: string): Promise<ProviderReceipt<"idle_stop"> | null>
  snapshot(machine: MachineRef, idempotencyKey: string): Promise<{ readonly receipt: ProviderReceipt<"snapshot">; readonly snapshot: MachineSnapshot }>
  fork(snapshot: MachineSnapshot, request: MachineRequest): Promise<ProviderReceipt<"fork">>
  estimate(shape: MachineShape): CostEstimate
  usage(machine: MachineRef, from: string, to: string): UsageReceipt
  attach(machine: MachineRef): Promise<{ readonly machine: MachineRef; readonly endpoint: string }>
}

export class ProviderContractError extends Error {
  constructor(readonly code: "provider.idempotency_conflict" | "provider.generation_conflict" | "provider.owner_conflict" | "provider.invalid_request" | "provider.not_found", message: string) {
    super(message)
    this.name = "ProviderContractError"
  }
}

type StoredMachine = {
  ref: MachineRef
  state: MachineState
  shape: MachineShape
  image: string
  region: string
  idleTimeoutSeconds: number
  lastActivityAt: number
}

type Clock = () => number

/**
 * Deterministic fake used by API tests and local integration experiments.
 * It deliberately exposes no provider credential and returns only redacted
 * handles, so tests can exercise GCP/Freestyle parity without live resources.
 */
export class FakeMachineProvider implements MachineProvider {
  readonly name = "fake"
  private readonly machines = new Map<string, StoredMachine>()
  private readonly receipts = new Map<string, { fingerprint: string; value: unknown }>()
  private readonly snapshots = new Map<string, MachineSnapshot>()
  private sequence = 0

  constructor(
    private readonly clock: Clock = () => Date.now(),
    private readonly rates: Omit<CostEstimate, "measuredAt" | "source"> & { readonly source?: string } = {
      currency: "USD",
      runningUsdMicrosPerHour: 132_240,
      storageUsdMicrosPerGbMonth: 86,
      egressUsdMicrosPerGb: 20_000,
    },
  ) {}

  private now(): string { return new Date(this.clock()).toISOString() }

  private remember<T>(key: string, fingerprint: string, create: () => T): T {
    const old = this.receipts.get(key)
    if (old) {
      if (old.fingerprint !== fingerprint) throw new ProviderContractError("provider.idempotency_conflict", `idempotency key ${key} was reused with different input`)
      return old.value as T
    }
    const value = create()
    this.receipts.set(key, { fingerprint, value })
    return value
  }

  private assertRequest(request: MachineRequest): void {
    if (!request.owner || !request.idempotencyKey || !request.region || !request.image || request.idleTimeoutSeconds < 0 || request.shape.cpu < 1 || request.shape.memoryMb < 1 || request.shape.diskGb < 1) {
      throw new ProviderContractError("provider.invalid_request", "owner, region, image and positive resources are required")
    }
  }

  private get(machine: MachineRef): StoredMachine {
    const found = this.machines.get(machine.id)
    if (!found) throw new ProviderContractError("provider.not_found", `machine ${machine.id} does not exist`)
    if (found.ref.owner !== machine.owner) throw new ProviderContractError("provider.owner_conflict", "machine belongs to another owner")
    if (found.ref.generation !== machine.generation) throw new ProviderContractError("provider.generation_conflict", "machine generation is stale")
    return found
  }

  private receipt<T extends MachineOperation>(operation: T, key: string, m: StoredMachine, details?: Readonly<Record<string, string>>): ProviderReceipt<T> {
    return { operation, provider: this.name, idempotencyKey: key, machine: m.ref, state: m.state, occurredAt: this.now(), ...(details ? { details } : {}) }
  }

  async allocate(request: MachineRequest): Promise<ProviderReceipt<"allocate">> {
    this.assertRequest(request)
    const fingerprint = JSON.stringify({ owner: request.owner, region: request.region, shape: request.shape, image: request.image, idleTimeoutSeconds: request.idleTimeoutSeconds })
    return this.remember(request.idempotencyKey, fingerprint, () => {
      const id = `fake-machine-${++this.sequence}`
      const m: StoredMachine = {
        ref: { id, owner: request.owner, generation: 1 }, state: "running", shape: request.shape,
        image: request.image, region: request.region, idleTimeoutSeconds: request.idleTimeoutSeconds, lastActivityAt: this.clock(),
      }
      this.machines.set(id, m)
      return this.receipt("allocate", request.idempotencyKey, m, { region: request.region, image: request.image })
    })
  }

  async start(machine: MachineRef, idempotencyKey: string): Promise<ProviderReceipt<"start">> {
    return this.remember(idempotencyKey, JSON.stringify({ operation: "start", machine }), () => {
      const m = this.get(machine)
      if (m.state === "stopped") { m.state = "running"; m.ref = { ...m.ref, generation: m.ref.generation + 1 } }
      m.lastActivityAt = this.clock()
      return this.receipt("start", idempotencyKey, m)
    })
  }

  async stop(machine: MachineRef, idempotencyKey: string): Promise<ProviderReceipt<"stop">> {
    return this.remember(idempotencyKey, JSON.stringify({ operation: "stop", machine }), () => {
      const m = this.get(machine)
      if (m.state === "running") { m.state = "stopped"; m.ref = { ...m.ref, generation: m.ref.generation + 1 } }
      return this.receipt("stop", idempotencyKey, m)
    })
  }

  async idleStop(machine: MachineRef, idempotencyKey: string, lastActivityAt: string): Promise<ProviderReceipt<"idle_stop"> | null> {
    const m = this.get(machine)
    const idleAt = Date.parse(lastActivityAt)
    if (!Number.isFinite(idleAt) || this.clock() - idleAt < m.idleTimeoutSeconds * 1000 || m.state === "stopped") return null
    const stopped = await this.stop(machine, idempotencyKey)
    return { ...stopped, operation: "idle_stop" }
  }

  async snapshot(machine: MachineRef, idempotencyKey: string): Promise<{ receipt: ProviderReceipt<"snapshot">; snapshot: MachineSnapshot }> {
    const result = this.remember(idempotencyKey, JSON.stringify({ operation: "snapshot", machine }), () => {
      const m = this.get(machine)
      const snapshot: MachineSnapshot = { id: `fake-snapshot-${this.snapshots.size + 1}`, source: m.ref, createdAt: this.now() }
      return { receipt: this.receipt("snapshot", idempotencyKey, m, { snapshotId: snapshot.id }), snapshot }
    })
    this.snapshots.set(result.snapshot.id, result.snapshot)
    return result
  }

  async fork(snapshot: MachineSnapshot, request: MachineRequest): Promise<ProviderReceipt<"fork">> {
    this.assertRequest(request)
    if (!this.snapshots.has(snapshot.id)) throw new ProviderContractError("provider.not_found", `snapshot ${snapshot.id} does not exist`)
    const fingerprint = JSON.stringify({ operation: "fork", snapshot: snapshot.id, owner: request.owner, region: request.region, shape: request.shape, image: request.image })
    return this.remember(request.idempotencyKey, fingerprint, () => {
      const id = `fake-machine-${++this.sequence}`
      const m: StoredMachine = { ref: { id, owner: request.owner, generation: 1 }, state: "running", shape: request.shape, image: request.image, region: request.region, idleTimeoutSeconds: request.idleTimeoutSeconds, lastActivityAt: this.clock() }
      this.machines.set(id, m)
      return this.receipt("fork", request.idempotencyKey, m, { snapshotId: snapshot.id })
    })
  }

  estimate(shape: MachineShape): CostEstimate {
    if (shape.cpu < 1 || shape.memoryMb < 1 || shape.diskGb < 1) throw new ProviderContractError("provider.invalid_request", "resources must be positive")
    const base = this.rates.runningUsdMicrosPerHour / 2
    return { currency: "USD", runningUsdMicrosPerHour: Math.round(base * shape.cpu), storageUsdMicrosPerGbMonth: this.rates.storageUsdMicrosPerGbMonth, egressUsdMicrosPerGb: this.rates.egressUsdMicrosPerGb, source: this.rates.source ?? "fake-list-rate", measuredAt: this.now() }
  }

  usage(machine: MachineRef, from: string, to: string): UsageReceipt {
    const m = this.get(machine)
    const start = Date.parse(from), end = Date.parse(to)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) throw new ProviderContractError("provider.invalid_request", "usage window must be valid and ordered")
    const estimate = this.estimate(m.shape)
    const runningSeconds = Math.floor((end - start) / 1000)
    return { machine: m.ref, from: new Date(start).toISOString(), to: new Date(end).toISOString(), runningSeconds, amountUsdMicros: Math.ceil(runningSeconds * estimate.runningUsdMicrosPerHour / 3600), estimate }
  }

  async attach(machine: MachineRef): Promise<{ machine: MachineRef; endpoint: string }> {
    const m = this.get(machine)
    m.lastActivityAt = this.clock()
    return { machine: m.ref, endpoint: `wss://fake.invalid/cloud/${encodeURIComponent(m.ref.id)}` }
  }
}
