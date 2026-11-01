import type { SqlStore } from "@cmux/ownership"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { networkMesh, type NetworkMesh } from "./network-mesh-read.ts"
import { networkBody } from "./network-policy-read.ts"
import type { Http } from "./team-domain-external.ts"
import { DriverError } from "./team-vm-driver.ts"

export interface CloudMeshRoute { readonly team: string; readonly tenant: string; readonly project: string; readonly origin: string }
interface LegacyIntent extends CloudMeshRoute { readonly version: 1; readonly key: string }
interface LabelledIntent extends CloudMeshRoute { readonly version: 2; readonly key: string; readonly body: { readonly displayName: string; readonly labels: { readonly role: "cloud" } } }
type Intent = LegacyIntent | LabelledIntent
const unavailable = (message: string, final = false) => new DriverError("cloud.provider.unavailable", `VM API network: ${message}`, final)
const NAME = "Cloud network"

/** This owner chooses its creation key before I/O; restarts and uncertain responses cannot choose another. */
export class CloudMeshCreation {
  constructor(private readonly sql: SqlStore, private readonly route: CloudMeshRoute, private readonly connection: VmApiConnection, private readonly http: Http) {}

  read(): Intent | null {
    if (!this.sql.exec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cloud_mesh_creation'").length) return null
    const row = this.sql.exec<{ data: string }>("SELECT data FROM cloud_mesh_creation WHERE id=1")[0]
    if (!row || row.data.length > 4096) throw unavailable("invalid stored mesh creation", true)
    let value: Intent
    try { value = JSON.parse(row.data) as Intent } catch { throw unavailable("invalid stored mesh creation", true) }
    if (!value || (value.version !== 1 && value.version !== 2) || typeof value.key !== "string" || !/^cloud-mesh:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.key)
      || Object.entries(this.route).some(([key, expected]) => value[key as keyof CloudMeshRoute] !== expected)) throw unavailable("mesh creation belongs to another owner route", true)
    if (value.version === 2 && (!value.body || typeof value.body.displayName !== "string" || value.body.displayName.length < 1 || value.body.displayName.length > 100
      || !value.body.labels || value.body.labels.role !== "cloud" || Object.keys(value.body.labels).length !== 1)) throw unavailable("invalid stored mesh creation body", true)
    return value
  }

  private begin(): Intent {
    const prior = this.read()
    if (prior) return prior
    const intent: Intent = { ...this.route, version: 2, key: `cloud-mesh:${crypto.randomUUID()}`, body: { displayName: NAME, labels: { role: "cloud" } } }
    this.sql.exec("CREATE TABLE IF NOT EXISTS cloud_mesh_creation (id INTEGER PRIMARY KEY CHECK (id=1), data TEXT NOT NULL)")
    this.sql.exec("INSERT OR IGNORE INTO cloud_mesh_creation (id, data) VALUES (1, ?)", JSON.stringify(intent))
    const stored = this.read()
    if (!stored) throw unavailable("mesh creation was not retained")
    return stored
  }

  async create(guard: () => Promise<void>): Promise<NetworkMesh> {
    const intent = this.begin()
    const body = intent.version === 2 ? { displayName: intent.body.displayName, labels: { role: intent.body.labels.role } } : { displayName: "Cloud network" }
    await guard()
    try {
      // The legacy /v1/meshes route on an older Worker ignores Idempotency-Key.
      const response = await this.http(new Request(`${this.connection.origin}/v1/mesh-creations`, {
        method: "POST", redirect: "manual", signal: AbortSignal.timeout(30_000),
        headers: { accept: "application/json", "content-type": "application/json", authorization: `Bearer ${this.connection.key}`, "x-cmux-team-id": this.route.tenant, "idempotency-key": intent.key },
        body: JSON.stringify(body)
      }))
      if (response.status !== 201) {
        await response.body?.cancel()
        throw unavailable(`mesh creation HTTP ${response.status}`, response.status >= 400 && response.status < 500 && response.status !== 409 && response.status !== 429)
      }
      const answer = await networkBody(response), value = networkMesh(answer)
      if (!value || answer?.displayName !== body.displayName) throw unavailable("unconfirmed mesh creation")
      await guard()
      const current = this.read()
      if (!current || JSON.stringify(current) !== JSON.stringify(intent)) throw unavailable("mesh creation changed", true)
      return value
    } catch (error) { if (error instanceof DriverError) throw error; throw unavailable("no readable mesh creation answer") }
  }
}
