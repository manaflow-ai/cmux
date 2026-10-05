import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { ReadResult } from "./owner-do.ts"
import { cloudDriver } from "./cloud-driver.ts"
import { parseBindRequest, sha256Hex, type BindReply } from "./cloud-link.ts"
import { parseSigningKeys, publicKeyset } from "./link-token.ts"
import { connectInfo, mintLinkToken, type MintReply } from "./cloud-connect.ts"
import { registerVmInstall, sendEphemeral, VmEventBuckets, vmEventEmit, vmSelfGet, vmStatusReport, type VmReply } from "./cloud-vm.ts"
import { TABLE_LEDGER, TABLE_MACHINE, type LedgerRow, type MachineRow } from "./domains/cloud.ts"
import { CloudCore } from "./cloud-do-core.ts"

/**
 * CloudDO, one per team (plans/cmux-next/state-placement.md 5): the machine registry, the
 * provider-call ledger, plan checks and the alarm that repairs interrupted provider calls.
 * Create and delete commit their ledger row first (the reducer), then this object runs the
 * provider call, one machine at a time (single flight), and commits the outcome as
 * `cloud.driver_result`. A crash between the call and that commit leaves the row pending; the
 * alarm runs it again, and the guarded driver finds the VM by its deterministic name.
 */
export class CloudDO extends CloudCore {
  override async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    if (principal.team !== entity) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    if (op === "cloud.vm.self.get") return ((r) => (r.ok ? { ...r, revision: String(this.boundEngine?.currentSeq ?? 0) } : r))(vmSelfGet(entity, principal, params, this.isBound(entity) ? this.bind(entity).rows : undefined))
    if (op === "cloud.machine.connect_info") {
      if (principal.kind !== "session" && !principal.grant_classes?.includes("read")) return { ok: false, code: "auth.forbidden", message: "grant does not cover read" }
      if (!this.isBound(entity)) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
      const r = await connectInfo(entity, this.bind(entity).rows, principal, params, () => this.teamConnectServices(entity), () => this.audit)
      return r.ok ? { ...r, revision: String(this.boundEngine?.currentSeq ?? 0) } : r
    }
    // An object nobody created: answer from an empty head for this entity, without creating it.
    if (!this.isBound(entity)) {
      const r = this.read({ team: entity, rev: 0, active: 0, saved: 0, pending: {}, changed: null }, op, params, principal)
      return r.ok ? { ...r, revision: "0" } : r
    }
    return super.readOp(entity, principal, op, params)
  }

  /**
   * 5.8 item 2, RPC from POST /v1/cloud/bind: the VM's bind agent spends its one-time token. The
   * token is hashed here, so the committed op, its event and the ledger never see it. Any token
   * problem is one auth.forbidden; an object nobody created answers the same without being created.
   */
  async bindMachine(entity: string, body: unknown): Promise<BindReply> {
    const forbidden = { ok: false as const, code: "auth.forbidden", message: "bind refused" }
    if (!this.isBound(entity)) return forbidden
    const req = parseBindRequest(body)
    if (!req) return { ok: false, code: "validation.invalid", message: "invalid bind request" }
    if (req.team !== entity) return forbidden
    // Review P2-2: check the token before anything costs the team (no limiter, no engine, no ledger
    // row), so a caller who knows the team id can neither block the real agent nor fill the ledger.
    // The reducer checks the same again inside the commit (single use under concurrency).
    const token_sha256 = await sha256Hex(req.bind_token)
    const m = this.bind(entity).rows.get<MachineRow>(TABLE_MACHINE, req.machine)?.row
    const now = Date.now() + this.skewMs
    if (!m?.bind || !m.host_id || m.bind.spent || m.bind.token_sha256 !== token_sha256 || now > m.bind.expires_at || m.status === "deleting" || m.status === "failed") return forbidden
    const keys = parseSigningKeys(this.env.CLOUD_LINK_SIGNING_KEYS)
    // Without the link signing keyset a bound VM could never check a link token: refuse, token unspent.
    if (!keys) return { ok: false, code: "owner.unreachable", message: "link signing keys are not configured on this deployment" }
    const keyset = await publicKeyset(keys)
    const vm = await registerVmInstall(this.env, { creator: m.creator, team: entity, machine: req.machine, epoch: m.epoch ?? 1, jwk: req.install_public_jwk, ...(m.creator_sso_team ? { ssoTeam: m.creator_sso_team } : {}) })
    if (!vm.ok) return { ok: false, code: "owner.unreachable", message: "the VM install could not be registered; retry the bind" }
    const params = { machine: req.machine, token_sha256, wg_public_key: req.wg_public_key, daemon: req.daemon, keyset_version: keyset.version, vm_install: vm.id, now }
    // A fresh key per attempt: a second bind with a spent token must reach the reducer and be refused, never replay.
    const reply = this.submitSystem("cloud.machine.bind", params, `bind:${crypto.randomUUID()}`).frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t === "reject") {
      // A retried bind (same key) keeps the install the machine already names; any other refused bind's install ends.
      if (this.bind(entity).rows.get<MachineRow>(TABLE_MACHINE, req.machine)?.row.vm_install !== vm.id) this.vmRevokes.queue(vm.id, m.creator, "bind refused", now)
      await this.drainRevokes(now)
      return { ok: false, code: reply?.t === "reject" && reply.code === "validation.invalid" ? "validation.invalid" : "auth.forbidden", message: "bind refused" }
    }
    if (reply.t !== "result") return forbidden
    this.vmRevokes.bound(req.machine, vm.id, m.creator, now)
    await this.drainRevokes(now)
    return { ok: true, value: { ...(reply.value as Record<string, unknown>), keyset, install: { id: vm.id, user: m.creator, grant: vm.grant } } }
  }

  /** RPC from the Worker for cloud.machine.link_token: outside the op stream (no event, no ledger replay). */
  /** RPC from the Worker for cloud.vm.status.report and cloud.vm.event.emit (VM installs, own machine only; cloud-vm.ts). */
  async vmOp(entity: string, principal: Principal, op: string, params: unknown): Promise<VmReply> {
    const rows = this.isBound(entity) ? this.bind(entity).rows : undefined
    const now = Date.now() + this.skewMs
    if (op === "cloud.vm.status.report") return vmStatusReport(entity, principal, params, rows, this.vmStatus, (machine, report) => this.submitSystem("cloud.machine.vm_status", { machine, report, now }, `vm-status:${machine}:${now}`), now)
    return vmEventEmit(entity, principal, params, rows, this.vmEvents, (f) => sendEphemeral(this.ctx.getWebSockets(), f, (ws, a) => this.socketLive(ws, a as never) && a.principal.team === entity && a.principal.install_kind !== "vm"), now)
  }
  private readonly vmEvents = new VmEventBuckets()

  async mintLinkToken(entity: string, principal: Principal, params: unknown, request: string = crypto.randomUUID()): Promise<MintReply> {
    if (principal.team !== entity) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    const rows = this.isBound(entity) ? this.bind(entity).rows : undefined
    // Review P3-6: a bound limit per install (the limiter keeps no storage in this object).
    const limit = this.env.CLOUD_MUTATION_LIMIT
    if (rows && principal.install && limit && !(await limit.limit({ key: `cloud-link:${principal.install}` })).success) return { ok: false, code: "cloud.rate_limited", message: "too many link tokens; retry in a minute" }
    const keys = parseSigningKeys(this.testLinkKeys ?? this.env.CLOUD_LINK_SIGNING_KEYS)
    // Review P3-b: never sign an iss this deployment cannot name.
    const environment = this.envTag()
    if (!environment) return { ok: false, code: "owner.unreachable", message: "this deployment has no Cloud environment tag" }
    return mintLinkToken({ entity, rows, p: principal, params, request, environment, keys }, () => this.teamConnectServices(entity), () => this.audit)
  }

  /** The team's cloud.connectServices from its TeamDO (fail closed: a failed RPC fails the read). */
  private teamConnectServices(entity: string): Promise<ReadonlyArray<string>> {
    const stub = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity)) as unknown as { cloudConnectServices(e: string): Promise<ReadonlyArray<string>> }
    return stub.cloudConnectServices(entity)
  }

  /**
   * Operator action (route /v1/admin/cloud/abandoned/clear: admin key plus a person's session):
   * clear one abandoned ledger row. Refused unless a provider lookup of the recorded name, done
   * now, finds no VM. The clear and its audit row (who, when, why) commit together.
   */
  async clearAbandoned(entity: string, machine: string, who: { user: string; email: string | null }, reason: string): Promise<{ ok: true; audit: Record<string, unknown> } | { ok: false; code: string; message: string }> {
    const engine = this.boundEngine
    if (!engine || this.boundEntity() !== entity) return { ok: false, code: "not_abandoned", message: "no abandoned ledger row for that machine" }
    const stored = engine.rows.range<LedgerRow>(TABLE_LEDGER, { limit: 1000 }).find((l) => l.row.machine === machine && l.row.state === "abandoned")
    if (!stored) return { ok: false, code: "not_abandoned", message: "no abandoned ledger row for that machine" }
    const driver = cloudDriver(this.env, this.sqlStore)
    if (!driver) return { ok: false, code: "provider_unavailable", message: "no Cloud provider is configured, so the recorded name cannot be checked" }
    const found = await driver.peek(stored.row.provider_name).catch(() => undefined)
    if (found === undefined) return { ok: false, code: "provider_unavailable", message: "the provider lookup failed; try again" }
    if (found !== null) return { ok: false, code: "vm_present", message: "a VM exists under the recorded name; delete or adopt it by hand first" }
    const r = this.submitSystem("cloud.abandoned_clear", { key: stored.key, by: who.user, by_email: who.email, reason, at: Date.now() }, `abandoned-clear:${stored.key}`)
    const f = r.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: { audit: Record<string, unknown> }; code?: string; message?: string } | undefined
    if (!f || f.t !== "result" || !f.value) return { ok: false, code: f?.code ?? "not_abandoned", message: f?.message ?? "not cleared" }
    console.warn(JSON.stringify({ event: "cloud.abandoned.cleared", team: entity, machine, by: who.user, reason_chars: reason.length }))
    return { ok: true, audit: f.value.audit }
  }

  /** Test only (ENVIRONMENT=test): drive the fake provider and the object's clock. */
  async fakeControl(cmd: { fail_revokes?: number; link_keys?: string; unset?: ReadonlyArray<"CLOUD_API_ORIGIN" | "ENVIRONMENT_TAG" | "CLOUD_ALLOWED_TEAMS">; fail_next?: number; drop_results?: number; advance_ms?: number; delete_vm?: string; fail_list?: boolean; add_vm?: { name: string; team: string; machine: string } }) {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    cloudDriver(this.env, this.sqlStore)
    if (cmd.unset) this.testUnset = new Set(cmd.unset)
    if (cmd.link_keys !== undefined) this.testLinkKeys = cmd.link_keys
    if (cmd.fail_revokes !== undefined) this.failRevokes = cmd.fail_revokes
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.drop_results !== undefined) this.dropResults = cmd.drop_results
    if (cmd.fail_list !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_list = ? WHERE id = 1`, cmd.fail_list ? 1 : 0)
    if (cmd.advance_ms !== undefined) this.skewMs += cmd.advance_ms
    if (cmd.delete_vm !== undefined) this.sqlStore.exec(`DELETE FROM cloud_fake_vm WHERE name = ?`, cmd.delete_vm)
    if (cmd.add_vm !== undefined) {
      const t = { cmux_next_team: cmd.add_vm.team, cmux_next_machine: cmd.add_vm.machine }
      this.sqlStore.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle) VALUES (?, ?, ?, NULL)`, cmd.add_vm.name, `fs-${cmd.add_vm.name}`, JSON.stringify(t))
    }
    const ctl = this.sqlStore.exec<{ creates: number; deletes: number }>(`SELECT creates, deletes FROM cloud_fake_ctl WHERE id = 1`)[0]!
    const vms = this.sqlStore.exec<{ name: string; id: string; idle: number | null }>(`SELECT name, id, idle FROM cloud_fake_vm ORDER BY name`)
    const files = this.sqlStore.exec<{ vm: string; path: string; content: string; mode: number }>(`SELECT vm, path, content, mode FROM cloud_fake_file ORDER BY vm`).map((f) => ({ ...f, mode: Number(f.mode) }))
    return { files, audit: this.audit.list(), creates: ctl.creates, deletes: ctl.deletes, vms, pending: Object.keys(this.boundEngine?.currentState.pending ?? {}).length, suspects: this.sweep.suspects(), sweep_at: this.sweep.at(), vm_revokes: this.vmRevokes.pending(), now: Date.now() + this.skewMs }
  }
}
