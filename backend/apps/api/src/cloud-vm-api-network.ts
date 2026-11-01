import type { SqlStore } from "@cmux/ownership"
import { NativeMeshId, NativeTenantId, type CloudVmNetwork } from "@cmux/protocol"
import { Schema } from "effect"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { meshCidr, readNetworkMesh, type NetworkMesh } from "./network-mesh-read.ts"
import { networkBody } from "./network-policy-read.ts"
import type { Http } from "./team-domain-external.ts"
import { DriverError } from "./team-vm-driver.ts"
import { CloudMeshCreation, type CloudMeshRoute as Route } from "./cloud-vm-api-mesh-create.ts"

export interface CloudNetworkTarget extends NetworkMesh { readonly tenant: string }
type Pin = Route & NetworkMesh
const unavailable = (message: string, final = false) => new DriverError("cloud.provider.unavailable", `VM API network: ${message}`, final)
const same = (a: Pin, b: Pin) => a.team === b.team && a.tenant === b.tenant && a.project === b.project && a.origin === b.origin && a.mesh === b.mesh && a.ipv4_cidr === b.ipv4_cidr

/** One durable Cloud mesh per owner. Reads never create a table; uncertain I/O cannot retarget the pin. */
class CloudMeshPin {
  constructor(private readonly sql: SqlStore, private readonly route: Route) {}
  read(): Pin | null {
    if (!this.sql.exec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cloud_mesh_target'").length) return null
    const row = this.sql.exec<{ data: string }>("SELECT data FROM cloud_mesh_target WHERE id=1")[0]
    if (!row || row.data.length > 4096) throw unavailable("invalid stored target", true)
    let p: Pin
    try { p = JSON.parse(row.data) as Pin } catch { throw unavailable("invalid stored target", true) }
    if (!p || !Schema.is(NativeMeshId)(p.mesh) || !Schema.is(NativeTenantId)(p.tenant) || !meshCidr(p.ipv4_cidr)
      || Object.entries(this.route).some(([key, value]) => p[key as keyof Route] !== value)) throw unavailable("stored target belongs to another owner route", true)
    return p
  }
  pin(value: Pin): void {
    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_mesh_target (id INTEGER PRIMARY KEY CHECK (id=1), data TEXT NOT NULL)")
    this.sql.exec("INSERT OR IGNORE INTO cloud_mesh_target (id, data) VALUES (1, ?)", JSON.stringify(value))
    const stored = this.read()
    if (!stored || !same(stored, value)) throw unavailable("the Cloud mesh cannot be retargeted", true)
  }
}

/** Confirmed provider membership; the install/peer policy and service handshake remain independent. */
export class VmApiCloudNetwork {
  private readonly pin: CloudMeshPin
  private readonly creation: CloudMeshCreation
  constructor(private readonly connection: VmApiConnection, private readonly route: Route, sql: SqlStore,
              private readonly http: Http, private readonly current: () => Promise<boolean>) {
    this.pin = new CloudMeshPin(sql, route)
    this.creation = new CloudMeshCreation(sql, route, connection, http)
  }

  async prepare(active: () => boolean = () => true): Promise<CloudNetworkTarget> {
    const guard = async () => {
      if (!active() || !await this.current() || !active()) throw unavailable("the creation or owner route is no longer active", true)
    }
    const finish = (value: NetworkMesh): CloudNetworkTarget => {
      const target = { ...this.route, ...value }
      this.pin.pin(target)
      return { tenant: target.tenant, mesh: target.mesh, ipv4_cidr: target.ipv4_cidr }
    }
    const prior = this.pin.read()
    await guard()
    if (!prior && this.creation.read()) return finish(await this.creation.create(guard))
    const read = await readNetworkMesh(this.http, this.connection, this.route.tenant, prior?.mesh)
    await guard()
    if (!prior) {
      // Decide synchronously: a pinned mesh and a creation intent cannot race into two selections.
      if (this.pin.read()) return this.prepare(active)
      if (this.creation.read() || (!read.ok && read.empty)) return finish(await this.creation.create(guard))
    }
    if (!read.ok) throw unavailable(read.message, read.code !== "owner.unreachable")
    const target = { ...this.route, ...read.value }
    if (prior && !same(prior, target)) throw unavailable("the Cloud mesh changed", true)
    // The selected identity lands before the VM is allocated or an attach can be sent.
    return finish(read.value)
  }

  /** Read a pinned membership without discovery, allocation or an attachment write. */
  async read(vm: string, target: typeof CloudVmNetwork.Type, ownsVm: () => Promise<boolean>): Promise<typeof CloudVmNetwork.Type> {
    const pinned = this.pin.read()
    const valid = async () => (await Promise.all([this.current(), ownsVm()])).every(Boolean)
    if (!pinned || !same(pinned, { ...this.route, ...target }) || !await valid()) throw unavailable("unconfirmed member identity", true)
    try {
      const response = await this.http(new Request(`${this.connection.origin}/v1/meshes/${target.mesh}/vms/${vm}`, {
        method: "GET", redirect: "manual", signal: AbortSignal.timeout(30_000),
        headers: { accept: "application/json", authorization: `Bearer ${this.connection.key}`, "x-cmux-team-id": this.route.tenant }
      }))
      if (response.status !== 200) { await response.body?.cancel(); throw unavailable(`member HTTP ${response.status}`) }
      const body = await networkBody(response)
      if (!body || body.meshId !== target.mesh || body.vmId !== vm || (body.ipv4 !== null && !addressInMesh(body.ipv4, target.ipv4_cidr))) throw unavailable("unconfirmed member answer")
      if (!await valid()) throw unavailable("the member owner route changed", true)
      const live = this.pin.read()
      if (!live || !same(live, pinned)) throw unavailable("the member owner route changed", true)
      return { tenant: target.tenant, mesh: target.mesh, ipv4_cidr: target.ipv4_cidr, ipv4: body.ipv4 as string | null }
    } catch (error) { if (error instanceof DriverError) throw error; throw unavailable("no readable member answer") }
  }

  async attach(vm: string, target: CloudNetworkTarget): Promise<typeof CloudVmNetwork.Type> {
    const pinned = this.pin.read()
    if (!pinned || !/^vm_[0-9a-hjkmnp-tv-z]{26}$/.test(vm) || !same(pinned, { ...this.route, ...target }) || !await this.current()) throw unavailable("unconfirmed attachment identity", true)
    try {
      const response = await this.http(new Request(`${this.connection.origin}/v1/meshes/${target.mesh}/vms/${vm}`, {
        method: "PUT", redirect: "manual", signal: AbortSignal.timeout(30_000),
        headers: { accept: "application/json", authorization: `Bearer ${this.connection.key}`, "x-cmux-team-id": this.route.tenant }
      }))
      if (response.status !== 200) { await response.body?.cancel(); throw unavailable(`attachment HTTP ${response.status}`, response.status >= 400 && response.status < 500 && response.status !== 429 && response.status !== 409) }
      const body = await networkBody(response)
      if (!body || body.meshId !== target.mesh || body.vmId !== vm || (body.ipv4 !== null && !addressInMesh(body.ipv4, target.ipv4_cidr))) throw unavailable("unconfirmed attachment")
      if (!await this.current()) throw unavailable("the owner route changed", true)
      const after = this.pin.read()
      if (!after || !same(after, pinned)) throw unavailable("the Cloud mesh changed", true)
      return { tenant: target.tenant, mesh: target.mesh, ipv4_cidr: target.ipv4_cidr, ipv4: body.ipv4 as string | null }
    } catch (error) { if (error instanceof DriverError) throw error; throw unavailable("no readable attachment answer") }
  }
}

export const addressInMesh = (value: unknown, cidr: string): value is string => {
  if (typeof value !== "string" || !/^\d{1,3}(\.\d{1,3}){3}$/.test(value) || !meshCidr(cidr)) return false
  const parts = value.split(".").map(Number)
  if (parts.some((n) => n > 255) || parts.join(".") !== value) return false
  const base = cidr.split("/")[0]!.split(".").map(Number)
  return parts[0] === base[0] && parts[1] === base[1] && Math.floor(parts[2]! / 16) === Math.floor(base[2]! / 16)
    && !(parts[2] === base[2] && parts[3] === 0) && !(parts[2] === base[2]! + 15 && parts[3] === 255)
}
