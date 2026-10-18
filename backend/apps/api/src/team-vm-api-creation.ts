import type { VmCreationReceipt } from "@cmux/vm"
import type { TeamVmCreateSpec } from "./team-vm-api-config.ts"
import { TeamVmApiRequest, teamApiFailure, TEAM_API_VM_ID } from "./team-vm-api-request.ts"

/** Receipts recover only the pinned intent. Missing or legacy evidence never extends create permission. */
export async function recoverTeamVmCreation(api: TeamVmApiRequest, name: string, labels: Record<string, string>, spec: TeamVmCreateSpec, reconcile: boolean): Promise<string | null> {
  const params = { header: { "idempotency-key": `team-vm-create:${name}` } }
  const read = await api.request(() => api.client.GET("/v1/vm-creations/by-key", { params }))
  if (read.response.status === 404) return null
  let status = api.value(read)
  if (status.state === "pending" && reconcile) status = api.value(await api.request(() => api.client.POST("/v1/vm-creations/by-key/reconcile", { params })))
  if (status.state === "unresolved") return null
  if (status.state === "pending") {
    if (!reconcile) return null
    throw teamApiFailure("the original create is still pending")
  }
  if (status.state !== "committed" || !status.receipt || !matches(status.receipt, status.id, name, labels, spec)) throw teamApiFailure("unconfirmed retained creation receipt", true)
  return status.receipt.id
}

function matches(receipt: VmCreationReceipt, id: string | null, name: string, labels: Record<string, string>, spec: TeamVmCreateSpec): boolean {
  return typeof id === "string" && TEAM_API_VM_ID.test(id) && receipt.id === id && receipt.displayName === name
    && Object.entries(labels).every(([k, v]) => receipt.labels?.[k] === v)
    && receipt.idleTimeoutSeconds === spec.idleTimeoutSeconds && receipt.bootImage?.id === spec.image.id && receipt.bootImage?.revision === spec.image.revision
    && receipt.initialNetwork?.publicEgress === true && Array.isArray(receipt.initialNetwork.httpsProxyHosts) && receipt.initialNetwork.httpsProxyHosts.length === 0
}
