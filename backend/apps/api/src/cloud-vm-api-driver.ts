import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { cloudDriver, ENV_PREFIX, GuardedCloudDriver } from "./cloud-driver.ts"
import { transportOf, vmApiSettings, type CloudTransport } from "./cloud-vm-api-config.ts"
import { VmApiCloudDriver } from "./cloud-vm-api.ts"

/** Each call routes from an owner row. New deployment defaults never reinterpret an old resource. */
export const cloudDriverFor = async (env: Env, sql: SqlStore, team: string, row: { readonly transport?: CloudTransport }, purpose: "operate" | "cleanup" = "operate", fetchFn: typeof fetch = fetch): Promise<GuardedCloudDriver | null> => {
  const transport = transportOf(row)
  if (transport === "direct") return cloudDriver(env, sql)
  if (transport !== "vm-api") return null
  const settings = vmApiSettings(env), prefix = ENV_PREFIX[env.ENVIRONMENT]
  if (!settings || !prefix || prefix !== env.CLOUD_NAME_PREFIX) return null
  const owner = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as {
    vmApiTenant(entity: string, purpose: "operate" | "cleanup"): Promise<{ team: string; tenant: string; project: string } | null>
  }
  const target = await owner.vmApiTenant(team, purpose).catch(() => null)
  if (!target || target.team !== team || target.project !== env.STACK_PROJECT_ID || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(target.tenant)) return null
  return new GuardedCloudDriver(new VmApiCloudDriver(settings, target.tenant, team, fetchFn), prefix)
}
