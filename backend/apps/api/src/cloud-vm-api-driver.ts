import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { cloudDriver, ENV_PREFIX, GuardedCloudDriver } from "./cloud-driver.ts"
import { transportOf, vmApiSettings, type CloudTransport } from "./cloud-vm-api-config.ts"
import { VmApiCloudDriver } from "./cloud-vm-api.ts"
import { DriverError } from "./team-vm-driver.ts"
import type { EnsurePersonalTenantReply } from "./team-vm-api-personal.ts"
import { VmApiCloudNetwork } from "./cloud-vm-api-network.ts"

/** Each call routes from an owner row. New deployment defaults never reinterpret an old resource. */
export const cloudDriverFor = async (env: Env, sql: SqlStore, team: string, row: { readonly transport?: CloudTransport }, purpose: "operate" | "cleanup" = "operate", fetchFn: typeof fetch = fetch, provision = false): Promise<GuardedCloudDriver | null> => {
  const transport = transportOf(row)
  if (transport === "direct") return cloudDriver(env, sql)
  if (transport !== "vm-api") return null
  const settings = vmApiSettings(env), prefix = ENV_PREFIX[env.ENVIRONMENT]
  if (!settings || !prefix || prefix !== env.CLOUD_NAME_PREFIX) return null
  const owner = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as {
    vmApiTenant(entity: string, purpose: "operate" | "cleanup"): Promise<{ team: string; tenant: string; project: string } | null>
    ensureVmApiTenant(entity: string): Promise<EnsurePersonalTenantReply>
  }
  let target = await owner.vmApiTenant(team, purpose).catch(() => null)
  if (!target && provision && purpose === "operate") {
    const ensured = await owner.ensureVmApiTenant(team).catch(() => ({ status: "pending" as const }))
    if (ensured.status === "pending") throw new DriverError("cloud.provider.unavailable", "the personal VM tenant is still being confirmed", false)
    if (ensured.status !== "ready") return null
    target = await owner.vmApiTenant(team, purpose).catch(() => null)
  }
  if (!target || target.team !== team || target.project !== env.STACK_PROJECT_ID || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(target.tenant)) return null
  const route = { team: target.team, tenant: target.tenant, project: target.project, origin: settings.origin }
  const network = new VmApiCloudNetwork(settings, route, sql, (request) => fetchFn(request), async () => {
    const current = await owner.vmApiTenant(team, "operate").catch(() => null)
    return current?.team === route.team && current.tenant === route.tenant && current.project === route.project
  })
  return new GuardedCloudDriver(new VmApiCloudDriver(settings, target.tenant, team, fetchFn, network), prefix)
}
