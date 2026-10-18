import type { SqlStore } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { transportOf } from "./cloud-vm-api-config.ts"
import { teamVmApiSettings } from "./team-vm-api-config.ts"
import { VmApiTeamDriver } from "./team-vm-api-driver.ts"
import type { EnsurePersonalTenantReply } from "./team-vm-api-personal.ts"
import { DriverError, teamVmDriver, type TeamVmDriver, type TeamVmFiles } from "./team-vm-driver.ts"
import { type LedgerRow, TeamVmLedger } from "./team-vm-ledger.ts"

const refused = () => new DriverError("team_vm.not_configured", "the recorded Team VM transport is unavailable", true)

/** Sync owner dependency; each async operation resolves its exact ledger row, never the deployment default. */
export class TeamVmOwnerDriver implements TeamVmDriver {
  readonly files: TeamVmFiles
  private readonly direct: TeamVmDriver | null
  constructor(private readonly env: Env, sql: SqlStore, private readonly ledger: TeamVmLedger, private readonly team: string,
    private readonly mayCreate: (row: LedgerRow) => boolean) {
    this.direct = teamVmDriver(env, sql)
    this.files = {
      list: async (id, path) => (await this.byId(id, "cleanup")).files.list(id, path),
      stat: async (id, path) => (await this.byId(id, "cleanup")).files.stat(id, path),
      read: async (id, path, offset, signal) => (await this.byId(id, "cleanup")).files.read(id, path, offset, signal)
    }
  }
  slugPrefix(): string | null { return this.direct?.slugPrefix?.() ?? null }
  private async route(row: LedgerRow | undefined, purpose: "operate" | "cleanup", create = false): Promise<TeamVmDriver> {
    if (!row || row.team !== this.team || row.env !== (this.env.ENVIRONMENT ?? "unknown") || row.state === "deleted") throw refused()
    const transport = transportOf(row)
    if (transport === "direct") { if (!this.direct) throw refused(); return this.direct }
    if (transport !== "vm-api") throw refused()
    const settings = teamVmApiSettings(this.env)
    if (!settings) throw refused()
    const owner = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(this.team)) as unknown as {
      vmApiTenant(entity: string, purpose: "operate" | "cleanup"): Promise<{ team: string; tenant: string; project: string } | null>
      ensureVmApiTenant(entity: string): Promise<EnsurePersonalTenantReply>
    }
    if (create && !this.mayCreate(row)) throw refused()
    let target = await owner.vmApiTenant(this.team, purpose).catch(() => null)
    if (!target && create) {
      if (!this.mayCreate(row)) throw refused()
      const ensured = await owner.ensureVmApiTenant(this.team).catch(() => ({ status: "pending" as const }))
      if (ensured.status === "pending") throw new DriverError("team_vm.provider_failed", "the personal VM tenant is still being confirmed", false)
      if (ensured.status !== "ready") throw refused()
      target = await owner.vmApiTenant(this.team, purpose).catch(() => null)
    }
    if (!target || target.team !== this.team || target.project !== this.env.STACK_PROJECT_ID || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(target.tenant)) throw refused()
    if (create && !this.mayCreate(row)) throw refused()
    return new VmApiTeamDriver(settings, target.tenant, row, this.ledger, () => this.mayCreate(row))
  }
  private byId(id: string, purpose: "operate" | "cleanup" = "operate") { return this.route(this.ledger.byId(id), purpose) }
  async instanceMatches(id: string, signed: string): Promise<boolean> {
    const driver = await this.byId(id)
    return driver.instanceMatches ? driver.instanceMatches(id, signed) : id === signed
  }
  async ensureVm(name: string, team: string, epoch: number) {
    const row = this.ledger.byName(name)
    return (await this.route(row, "operate", !row?.provider_id)).ensureVm(name, team, epoch)
  }
  async ensureRunning(id: string) { return (await this.byId(id)).ensureRunning(id) }
  async exec(id: string, command: string, timeout: number) { return (await this.byId(id)).exec(id, command, timeout) }
  async lookup(name: string) { return (await this.route(this.ledger.byName(name), "cleanup")).lookup(name) }
  async retireVm(id: string) { return (await this.byId(id, "cleanup")).retireVm(id) }
  async deleteVm(id: string) { return (await this.byId(id, "cleanup")).deleteVm(id) }
  async listPage(): ReturnType<TeamVmDriver["listPage"]> { throw refused() }
}
