import { createServerFn } from "@tanstack/react-start"
import { mockAppsMutate, mockAppsRead } from "./apps-mock"
import { mutate, read, type Json, type OpResponse } from "./server"

/** Shapes of the app store ops the dashboard shows (backend/packages/protocol/src/apps.ts). */
export type Tier = "first-party" | "verified" | "unverified"

export interface VersionRecord {
  version: string
  engines: { cmux: string }
  scopes: Record<string, string>
  optional_scopes: Record<string, string>
  added_scopes: Array<string>
  published_at: number
  yanked: boolean
  yank_reason: string | null
}

export interface Listing {
  id: string
  name: string
  description: string
  publisher: { name: string; github_owner: string; verified: boolean }
  repository: string
  categories: Array<string>
  tier: Tier
  latest_version: string | null
  install_count: number
  versions?: Array<VersionRecord>
}

export interface Install {
  app: string
  scope: "user" | "team"
  version: string
  tier: Tier
  scopes_granted: Array<string>
  installed_at: number
  hidden: boolean
  by_default?: boolean
}

export interface Approval {
  id: string
  kind: "install" | "update"
  app: string
  scope: "user" | "team"
  version: string
  scopes: Array<string>
  added: Array<string>
  requested_by: { identity: string; origin: string }
  expires_at: number
}

export interface InstallsView {
  installs: Array<Install>
  approvals: Array<Approval>
  policy: { allowed_tiers: Array<Tier> | null; allowlist: Array<string> | null; blocklist: Array<string> } | null
}

/** Dev-only mock data (no API, no sign-in) when CMUX_DASHBOARD_APPS_MOCK=1 outside production. */
const mockOn = () => process.env.CMUX_DASHBOARD_APPS_MOCK === "1" && process.env.NODE_ENV !== "production"

/** app.* reads: the API (or the dev mock). */
export const appsRead = createServerFn({ method: "POST" })
  .validator((d: { op: string; params: Record<string, unknown> }) => d)
  .handler(async ({ data }): Promise<{ status: number; body: { value?: Json; code?: string; message?: string } }> => {
    if (mockOn()) return mockAppsRead(data.op, data.params)
    const r = await read({ data })
    return { status: r.status, body: r.body as { value?: Json } }
  })

/** app.* mutations with origin user: the API (or the dev mock). */
export const appsMutate = createServerFn({ method: "POST" })
  .validator((d: { op: string; params: Record<string, unknown>; idempotency_key: string }) => d)
  .handler(async ({ data }): Promise<{ status: number; body: OpResponse }> => {
    if (mockOn()) return mockAppsMutate(data.op, data.params, data.idempotency_key)
    return mutate({ data })
  })

export const describeError = (r: { status: number; body: { error?: { code: string; message: string }; code?: string; message?: string } }) =>
  r.body.error ? `${r.body.error.code}: ${r.body.error.message}` : r.body.code ? `${r.body.code}: ${r.body.message ?? ""}` : `request failed (${r.status})`
