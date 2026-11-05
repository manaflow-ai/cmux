import type { Env } from "./env.ts"
import type { SqlStore } from "@cmux/ownership"
import { vmApiSettings, type CloudTransport } from "./cloud-vm-api-config.ts"
import { requiredSlugPrefix, teamVmDriver } from "./team-vm-driver.ts"
import { freestyleIdleSeconds } from "./auto-pause.ts"

export interface TeamVmCreateSpec { readonly image: { readonly id: string; readonly revision: string }; readonly idleTimeoutSeconds: number }
export const teamVmCreationTransport = (env: Env): CloudTransport | null =>
  env.TEAM_VM_TRANSPORT === undefined || env.TEAM_VM_TRANSPORT === "direct" ? "direct" : env.TEAM_VM_TRANSPORT === "vm-api" ? "vm-api" : null
export const teamVmApiSettings = (env: Env) => vmApiSettings({ ...env,
  CLOUD_VM_API_ORIGIN: env.TEAM_VM_API_ORIGIN ?? "", CLOUD_VM_API_SERVICE_KEY: env.TEAM_VM_API_SERVICE_KEY ?? "",
  CLOUD_VM_API_IMAGE: env.TEAM_VM_API_IMAGE ?? "", CLOUD_VM_API_IMAGE_REVISION: env.TEAM_VM_API_IMAGE_REVISION ?? "" })
export const teamVmCreateSpec = (env: Env): TeamVmCreateSpec | null => {
  const settings = teamVmApiSettings(env)
  if (!settings || !env.TEAM_VM_SLUG_PREFIX || (env.ENVIRONMENT !== "production" && !env.TEAM_VM_SLUG_PREFIX.startsWith(requiredSlugPrefix(env.ENVIRONMENT)))) return null
  // -1 (never pause) unless CLOUD_IDLE_PAUSE is on (auto-pause.ts; Leo, 2026-10-30).
  return { image: settings.image, idleTimeoutSeconds: freestyleIdleSeconds(env, env.ENVIRONMENT === "production" ? 600 : 300) }
}
export const teamVmCreationReady = (env: Env, sql: SqlStore): boolean => {
  const transport = teamVmCreationTransport(env)
  return transport === "direct" ? teamVmDriver(env, sql) !== null : transport === "vm-api" && teamVmCreateSpec(env) !== null
}
export const parseTeamVmCreateSpec = (text: string | null): TeamVmCreateSpec | null => {
  try {
    const v = JSON.parse(text ?? "null") as TeamVmCreateSpec | null
    return v && typeof v.image?.id === "string" && typeof v.image.revision === "string" && /^[a-z][a-z0-9-]{0,62}$/.test(v.image.id) && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(v.image.revision) && (v.idleTimeoutSeconds === -1 || v.idleTimeoutSeconds === 300 || v.idleTimeoutSeconds === 600) ? v : null
  } catch { return null }
}
