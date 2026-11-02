import { cloudVmReceiverPolicy } from "./cloud-vm-receiver-policy.ts"
import { cloudVmReceiverLifecycle } from "./cloud-vm-receiver-lifecycle.ts"
import { VmReceiverGenerations } from "./cloud-vm-receiver-generations.ts"
import { cloudDriverFor } from "./cloud-vm-api-driver.ts"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { ReadResult } from "./owner-do.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import { TEAM_MEMBER_LEFT_SOCKETS } from "./domains/team-members.ts"
import { roleHas } from "./domains/team-roles.ts"
import { cloudDriver, cloudConfig } from "./cloud-driver.ts"
import { parseBindRequest, sha256Hex, type BindReply } from "./cloud-link.ts"
import { parseSigningKeys, publicKeyset } from "./link-token.ts"
import { isMachineInstallKind } from "./machine-installs.ts"
import { connectInfo, machineBySelector, mintLinkToken, type MintReply } from "./cloud-connect.ts"
import { registerVmInstall, sendEphemeral, VmEventBuckets, vmEventEmit, vmGate, vmSelfGet, vmStatusReport, type VmReply } from "./cloud-vm.ts"
import type { TrajectoryScope } from "./cloud-trajectory.ts"
import { PLATFORM_IDENTITY_PREFIX, TABLE_LEDGER, TABLE_MACHINE, TABLE_SNAPSHOT, TABLE_TOMBSTONE, type CloudState, type LedgerRow, type MachineRow } from "./domains/cloud.ts"
import type { SnapshotRow } from "./domains/cloud-snapshot.ts"
import { platformCall, platformShape, type PlatformCall, type PlatformReply, type PlatformHost } from "./cloud-platform.ts"
import { PlatformOperations } from "./cloud-platform-operations.ts"
import { directCloudProvider } from "./providers/index.ts"
import { statusApplied } from "./cloud-do-core.ts"
import { CloudIdle } from "./cloud-do-idle.ts"
import { deliverCloudAnswers, readCloudApproval } from "./cloud-approvals.ts"
import type { DeliverResult, TargetItem } from "./do-outbox.ts"
import { acpmuxKeyedStartOn, acpmuxPersonHoldsOn, type AcpmuxHost, type AcpmuxReply } from "./cloud-acpmux-do.ts"
import type { MachineExecReply } from "./automation-machine.ts"
import { ClientIdentityStore, mintClientSessionOn, sweepClientIdentities, type ClientSessionReply } from "./cloud-client-session.ts"
import { teamPlan } from "./domains/cloud-plan.ts"
import { TEAM_MEMBER_AUTHORITY_CHANGED, TEAM_AUTHORITY_CHANGED } from "./domains/team-authority.ts"
import { CloudNetworkObservation } from "./cloud-network-observation.ts"
import type { NativeLinkAuthority } from "./cloud-connect.ts"
import { vmApiConnection } from "./cloud-vm-api-config.ts"
import { readVmReceiverPermit, sameVmReceiverPermit, type VmReceiverPermit } from "./cloud-vm-receiver-authority.ts"
import { DriverError } from "./providers/contract.ts"

/** How often connect_info and link_token may read a machine's real state from the provider. */
const STATE_CHECK_EVERY_MS = 30_000

/**
 * CloudDO, one per team (plans/cmux-next/state-placement.md 5): the machine registry, the
 * provider-call ledger, plan checks and the alarm that repairs interrupted provider calls.
 * Create and delete commit their ledger row first (the reducer), then this object runs the
 * provider call, one machine at a time (single flight), and commits the outcome as
 * `cloud.driver_result`. A crash between the call and that commit leaves the row pending; the
 * alarm runs it again, and the guarded driver finds the VM by its deterministic name.
 */
export class CloudDO extends CloudIdle {
  override async readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadResult> {
    if (principal.team !== entity) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    // cloud.plan.get answers the team's current paid plan (cloud-entitlements.ts).
    if (op === "cloud.plan.get") await this.entitlements.refresh(entity, principal)
    // G8 (cx-wb5.65): the person's own session reads the exact Cloud request it is asked to approve.
    if (op === "integration.approval.get") return ((r) => (r.ok ? { ...r, revision: String(this.boundEngine?.currentSeq ?? 0) } : r))(readCloudApproval(this.ctx.storage.sql, principal, params))
    if (op === "cloud.vm.self.get") return ((r) => (r.ok ? { ...r, revision: String(this.boundEngine?.currentSeq ?? 0) } : r))(vmSelfGet(entity, principal, params, this.isBound(entity) ? this.bind(entity).rows : undefined))
    if (op === "cloud.vm.network_policy") {
      const result = await cloudVmReceiverPolicy({ team: entity, now: () => Date.now() + this.skewMs,
        connection: () => vmApiConnection(this.env), revision: () => String(this.boundEngine?.currentSeq ?? 0), http: (r) => fetch(r),
        rows: this.isBound(entity) ? this.bind(entity).rows : undefined,
        generation: (machine, scope) => {
          const current = new VmReceiverGenerations(this.sqlStore).current(machine, scope)
          return current.phase === "starting" || current.phase === "ready" ? current.generation : null
        },
        own: (user, install, grant, machine) => this.env.USER_DO.get(this.env.USER_DO.idFromName(user)).vmNetworkIdentity(user, install, grant, entity, machine),
        peers: (target) => this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity)).vmReceiverPeers(entity, target),
        allocation: async (row, signal) => {
          const driver = await cloudDriverFor(this.env, this.sqlStore, entity, row, "operate", (input, init) => {
            const r = new Request(input, init)
            return fetch(new Request(r, { signal: AbortSignal.any([r.signal, signal]) }))
          })
          if (!driver || signal.aborted) return null
          const found = await driver.peek(row.provider_name)
          return found?.state === "running" && found.tag.cmux_next_team === entity && found.tag.cmux_next_machine === row.id ? found.id : null
        }
      }, principal, params)
      if (this.isBound(entity)) this.audit.record({ op: "vm_network_policy", machine: principal.bound_machine ?? null, user: principal.user ?? null,
        install: principal.install ?? null, at: Date.now() + this.skewMs, outcome: result.ok ? "ok" : "refused" })
      return result
    }
    if (op === "cloud.machine.connect_info") {
      if (principal.kind !== "session" && !principal.grant_classes?.includes("read")) return { ok: false, code: "auth.forbidden", message: "grant does not cover read" }
      if (!this.isBound(entity)) return { ok: false, code: "cloud.machine.not_found", message: "no such machine in this team" }
      await this.checkRealState(entity, (params ?? {}) as { machine?: string; host?: string })
      if (!await this.checkNetwork(entity, (params ?? {}) as { machine?: string; host?: string })) return { ok: false, code: "owner.unreachable", message: "the machine network is unavailable" }
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

  /** Members whose departure this instance heard (user -> when), for a socket accepted while the notice was in flight. */
  private readonly leftAt = new Map<string, number>()

  /**
   * A socket for a shared team is accepted only while TeamDO still lists the user (cx-3bi.43 review P3:
   * one RPC per connect, never per message). A departure notice that arrives during that RPC refuses
   * it too, so no socket opens between the Worker's check and the notice.
   */
  override async fetch(request: Request): Promise<Response> {
    const p = JSON.parse(request.headers.get("x-cmux-principal") ?? "null") as Principal | null
    if (p?.user && p.team && p.team !== personalTeamIdFor(p.user)) {
      const started = Date.now()
      const team = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(p.team)) as unknown as { memberRole(e: string, u: string): Promise<string | null> }
      const role = await team.memberRole(p.team, p.user).catch(() => null)
      // Guests and the billing role hold no team.resources grant (cx-3bi.4): no Cloud socket.
      if (!roleHas(role ?? undefined, "team.resources") || (this.leftAt.get(p.user) ?? -1) >= started) return new Response("forbidden", { status: 403 })
    }
    return super.fetch(request)
  }

  /** The person's approval answers (G8, cloud-approvals.ts) run here; other items go to the engine. */
  override async systemDeliver(entity: string, source: string, items: ReadonlyArray<TargetItem>): Promise<DeliverResult> {
    // A member left the team (cx-3bi.43 review P1-2): their sockets here close now; only this team's TeamDO may say so.
    const left = items.filter((i) => i.op === TEAM_MEMBER_LEFT_SOCKETS)
    for (const i of left) {
      const user = (i.params as { user?: unknown })?.user
      if (source !== `team:${entity}` || typeof user !== "string") continue
      this.leftAt.set(user, Date.now())
      if (this.isBound(entity)) this.closeSockets((p) => p.user === user, "left the team")
      // Their client sessions end now too: the identities (and every token on them) are deleted at the provider.
      if (this.hasClientIdentities()) {
        const theirs = this.clientIdentityStore().forgetUser(user, Date.now())
        await this.sweepClientIdentities(Date.now(), theirs).catch(() => this.retryClientIdentities())
      }
    }
    // Membership and policy authority notices are durable fences, not trusted payloads. Read the
    // current machine rows and close every affected receiver generation so delayed READY frames
    // cannot revive a grant after an A→B→A membership transition.
    const memberAuthority = items.filter((i) => i.op === TEAM_MEMBER_AUTHORITY_CHANGED)
    const teamAuthority = items.filter((i) => i.op === TEAM_AUTHORITY_CHANGED)
    const validAuthority = source === `team:${entity}`
    if (validAuthority && this.isBound(entity) && (memberAuthority.length || teamAuthority.length)) {
      const users = new Set(memberAuthority.flatMap((i) => {
        const user = (i.params as { user?: unknown })?.user
        return typeof user === "string" ? [user] : []
      }))
      // A membership role affects that user's peer authority on every VM in the team,
      // including machines created by another member. Any member or team policy notice
      // therefore fences all receiver generations in this CloudDO.
      const store = new VmReceiverGenerations(this.sqlStore)
      let after = Number.MIN_SAFE_INTEGER
      for (;;) {
        const page = this.bind(entity).rows.range<MachineRow>(TABLE_MACHINE, { after, limit: 1000 })
        for (const entry of page) store.close(entry.row.id, (audit) => this.audit.record({ op: "receiver_authority_close", team: entity, ...audit, at: Date.now() }))
        if (page.length < 1000) break
        const next = page[page.length - 1]!.n
        if (next === null || next <= after) break
        after = next
      }
      for (const user of users) this.closeSockets((p) => p.user === user, "team membership authority changed")
    }
    const answers = items.filter((i) => i.op === "integration.approval.answered")
    const rest = items.filter((i) => i.op !== "integration.approval.answered" && i.op !== TEAM_MEMBER_LEFT_SOCKETS && i.op !== TEAM_MEMBER_AUTHORITY_CHANGED && i.op !== TEAM_AUTHORITY_CHANGED)
    const authorityDone = validAuthority ? [...memberAuthority, ...teamAuthority].map((i) => i.id) : []
    const done = [...left.map((i) => i.id), ...authorityDone, ...(rest.length ? (await super.systemDeliver(entity, source, rest)).done : [])]
    if (answers.length) done.push(...(await deliverCloudAnswers(this.approvalHost(entity), source, answers, (p, f) => this.submitAs(entity, p, f), (e) => this.audit.record(e))).done)
    return { done }
  }

  /**
   * 5.8 item 2, RPC from POST /v1/cloud/bind: the VM's bind agent spends its one-time token. The
   * token is hashed here, so the committed op, its event and the ledger never see it. Any token
   * problem is one auth.forbidden; an object nobody created answers the same without being created.
   */
  /** TeamDO's fresh resource-membership read for `user` (tests replace it). */
  creatorIsMember = async (team: string, user: string): Promise<boolean> => {
    const stub = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team)) as unknown as { memberRole(e: string, u: string): Promise<string | null> }
    const role = await stub.memberRole(team, user)
    return roleHas(role ?? undefined, "team.resources")
  }

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
    // A creator who left this team gets no VM install bound to it (cx-44j.51); their personal team they never leave.
    if (entity !== personalTeamIdFor(m.creator) && !(await this.creatorIsMember(entity, m.creator))) return forbidden
    // The machine's creator_sso_team was seen fresh at its create (sso_seen_at), so UserDO stamps it unless the creator left that team later.
    const reg = { creator: m.creator, team: entity, machine: req.machine, epoch: m.epoch ?? 1, jwk: req.install_public_jwk, ...(m.creator_sso_team ? { ssoTeam: m.creator_sso_team, ssoSeenAt: m.created_at } : {}) }
    this.vmRevokes.beginRegister(reg, now)
    const vm = await registerVmInstall(this.env, reg)
    if (!vm.ok) return (vm.code !== "owner.unreachable" && this.vmRevokes.endRegister(reg), { ok: false, code: "owner.unreachable", message: "the VM install could not be registered; retry the bind" })
    const params = { machine: req.machine, token_sha256, wg_public_key: req.wg_public_key, daemon: req.daemon, keyset_version: keyset.version, vm_install: vm.id, now }
    // A fresh key per attempt: a second bind with a spent token must reach the reducer and be refused, never replay.
    const reply = this.submitSystem("cloud.machine.bind", params, `bind:${crypto.randomUUID()}`).frames.find((f) => f.t === "result" || f.t === "reject")
    if (!reply || reply.t === "reject") {
      // A retried bind (same key) keeps the install the machine already names; any other refused bind's install ends.
      if (this.bind(entity).rows.get<MachineRow>(TABLE_MACHINE, req.machine)?.row.vm_install !== vm.id) this.vmRevokes.queue(vm.id, m.creator, "bind refused", now)
      this.vmRevokes.endRegister(reg)
      await this.drainRevokes(now)
      return { ok: false, code: reply?.t === "reject" && reply.code === "validation.invalid" ? "validation.invalid" : "auth.forbidden", message: "bind refused" }
    }
    if (reply.t !== "result") return forbidden
    this.vmRevokes.bound(req.machine, vm.id, m.creator, now)
    this.vmRevokes.endRegister(reg)
    await this.drainRevokes(now)
    return { ok: true, value: { ...(reply.value as Record<string, unknown>), keyset, install: { id: vm.id, user: m.creator, grant: vm.grant } } }
  }

  /**
   * Coordinator decision (2026-10-05): before connect_info and link_token answer for a running record,
   * read the VM's real state (one cheap GET). A VM powered off or paused by itself is recorded paused,
   * a VM that is gone failed; a failed read keeps the record.
   */
  private readonly stateChecks = new Map<string, number>()
  private readonly networkObservation = new CloudNetworkObservation(
    () => Date.now() + this.skewMs,
    (entity, id) => this.isBound(entity) ? this.bind(entity).rows.get<MachineRow>(TABLE_MACHINE, id)?.row : undefined,
    async (row) => {
      const driver = await this.driverFor(row)
      if (!driver || !row.network) throw new Error("network unavailable")
      return driver.networkOf(row.provider_name, { team: this.boundEntity() ?? "", machine: row.id }, row.network)
    },
    (row, binding, network) => statusApplied(this.submitSystem("cloud.machine.network_observed", { machine: row.id, binding, network }, `network:${crypto.randomUUID()}`).frames)
  )
  private async checkNetwork(entity: string, sel: { machine?: string; host?: string }): Promise<boolean> {
    if (!this.isBound(entity)) return false
    const row = machineBySelector(this.bind(entity).rows, sel)
    return !row || await this.networkObservation.check(entity, row)
  }
  private async checkRealState(entity: string, sel: { machine?: string; host?: string }): Promise<void> {
    const row = sel.machine !== undefined || sel.host !== undefined ? machineBySelector(this.bind(entity).rows, sel) : undefined
    if (row?.status !== "running") return
    // At most one provider read per machine per 30 s (review P2-3: the API key is shared by every team).
    const now = Date.now() + this.skewMs
    const last = this.stateChecks.get(row.id)
    if (last !== undefined && now - last < STATE_CHECK_EVERY_MS) return
    const driver = await this.driverFor(row)
    if (!driver) return
    this.stateChecks.set(row.id, now)
    const r = await driver.stateOf(row.provider_name, { team: entity, machine: row.id }).catch(() => undefined)
    // Only a VM known gone, or explicitly paused or stopped, changes the record (review P2-2): any other or missing value is no change.
    if (!r || (!r.gone && r.state !== "paused" && r.state !== "stopped")) return
    this.submitSystem("cloud.machine.provider_state", { machine: row.id, state: r.gone ? null : r.state }, `provider-state:${row.id}:${this.boundEngine?.currentSeq ?? 0}`)
  }

  /** RPC from the Worker for cloud.machine.link_token: outside the op stream (no event, no ledger replay). */
  /** RPC from the Worker for cloud.vm.status.report and cloud.vm.event.emit (VM installs, own machine only; cloud-vm.ts). */
  async vmOp(entity: string, principal: Principal, op: string, params: unknown): Promise<VmReply> {
    const rows = this.isBound(entity) ? this.bind(entity).rows : undefined
    const now = Date.now() + this.skewMs
    if (op === "cloud.vm.receiver.lifecycle") return cloudVmReceiverLifecycle({ team: entity, rows, now: () => Date.now() + this.skewMs,
      sql: () => this.sqlStore,
      own: (user, install, grant, machine) => this.env.USER_DO.get(this.env.USER_DO.idFromName(user)).vmNetworkIdentity(user, install, grant, entity, machine),
      audit: (entry) => { if (this.isBound(entity)) this.audit.record({ op: "vm_receiver_lifecycle", user: principal.user ?? null, install: principal.install ?? null, at: Date.now() + this.skewMs, ...entry }) }
    }, principal, params)
    if (op === "cloud.vm.status.report") {
      let applied: { machine: string; report: unknown } | undefined
      const r = vmStatusReport(entity, principal, params, rows, this.vmStatus, (machine, report) => {
        if (statusApplied(this.submitSystem("cloud.machine.vm_status", { machine, report, now }, `vm-status:${machine}:${now}`).frames)) {
          this.vmStatus.markActivity(machine, report, now)
          applied = { machine, report }
        }
      }, now)
      if (applied) await this.considerIdlePause(entity, applied.machine, applied.report, now)
      // A held report commits nothing, so nothing moved the alarm: arm it for the end of the window
      // (VmStatusQueue.dueAt) so the latest held report applies then, not at an unrelated wake.
      else if (r.ok) this.scheduleAlarm()
      return r
    }
    return vmEventEmit(entity, principal, params, rows, this.vmEvents, (f) => sendEphemeral(this.ctx.getWebSockets(), f, (ws, a) => this.socketLive(ws, a as never) && a.principal.team === entity && a.principal.install_kind !== "vm"), now)
  }
  private readonly vmEvents = new VmEventBuckets()

  /**
   * #25584, RPC from POST /v1/cloud/machines/{machine}/trajectories/* (cloud-trajectory.ts): the machine whose
   * kept ACP chats this principal may use. Writes: the machine's own VM install only (the cloud.vm.* gate), into
   * that machine's store. Reads: that install, or the machine's creator (a session, or the creator's own install
   * with the read class). `parent`: the VM install reads its restore source's store (MachineRow.trajectory_parent),
   * or none. Not an op: nothing is committed.
   */
  async trajectoryScope(entity: string, principal: Principal, machine: string, write: boolean, parent: boolean): Promise<TrajectoryScope> {
    const rows = this.isBound(entity) ? this.bind(entity).rows : undefined
    if (principal.kind === "install" && principal.install_kind === "vm") {
      const g = vmGate(entity, principal, machine, rows)
      if (!g.ok) return { ok: false, status: g.code === "cloud.machine.not_found" ? 404 : 403, code: g.code, message: g.message }
      if (!parent) return { ok: true, store: g.row.id }
      return write ? { ok: false, status: 403, code: "auth.forbidden", message: "a restore source's chats are read only" } : { ok: true, store: g.row.trajectory_parent ?? null }
    }
    // Review 2 blocker: any other machine install (a team VM's) has no access to chats (machine-installs.ts).
    if (isMachineInstallKind(principal.install_kind)) return { ok: false, status: 403, code: "auth.forbidden", message: "a machine install has no access to chats" }
    if (write || parent) return { ok: false, status: 403, code: "auth.forbidden", message: "only the machine itself writes its chats" }
    if (principal.team !== entity || !principal.user) return { ok: false, status: 403, code: "auth.forbidden", message: "not this team's machines" }
    if (principal.kind === "install" && !principal.grant_classes?.includes("read")) return { ok: false, status: 403, code: "auth.forbidden", message: "this install cannot read" }
    const row = rows?.get<MachineRow>(TABLE_MACHINE, machine)?.row
    if (!row || row.creator !== principal.user) return { ok: false, status: 404, code: "cloud.machine.not_found", message: "no such machine of yours in this team" }
    return { ok: true, store: row.id }
  }

  async mintLinkToken(entity: string, principal: Principal, params: unknown, request: string = crypto.randomUUID()): Promise<MintReply> {
    if (principal.team !== entity) return { ok: false, code: "auth.forbidden", message: "not this team's machines" }
    const rows = this.isBound(entity) ? this.bind(entity).rows : undefined
    // Review P3-6: a bound limit per install (the limiter keeps no storage in this object).
    const limit = this.env.CLOUD_MUTATION_LIMIT
    if (rows && principal.install && limit && !(await limit.limit({ key: `cloud-link:${principal.install}` })).success) return { ok: false, code: "cloud.rate_limited", message: "too many link tokens; retry in a minute" }
    // After the limiter (review P2-3).
    if (rows && principal.kind === "install") await this.checkRealState(entity, { host: (params as { host?: string } | null)?.host })
    if (rows && principal.kind === "install" && !await this.checkNetwork(entity, { host: (params as { host?: string } | null)?.host })) return { ok: false, code: "owner.unreachable", message: "the machine network is unavailable" }
    const keys = parseSigningKeys(this.testLinkKeys ?? this.env.CLOUD_LINK_SIGNING_KEYS)
    // Review P3-b: never sign an iss this deployment cannot name.
    const environment = this.envTag()
    if (!environment) return { ok: false, code: "owner.unreachable", message: "this deployment has no Cloud environment tag" }
    return mintLinkToken({ entity, rows, p: principal, params, request, environment, keys, native: this.nativeLinkAuthority(entity) }, () => this.teamConnectServices(entity), () => this.audit)
  }

  /** Native VM API links are authorized against the current TeamDO identity/policy and receiver generation. */
  private nativeLinkAuthority(entity: string): NativeLinkAuthority {
    const receiver = (machine: string): Promise<VmReceiverPermit | null> => readVmReceiverPermit({
      team: entity,
      rows: this.isBound(entity) ? this.bind(entity).rows : undefined,
      sql: this.sqlStore,
      now: () => Date.now() + this.skewMs,
      own: (user, install, grant, id) => this.env.USER_DO.get(this.env.USER_DO.idFromName(user)).vmNetworkIdentity(user, install, grant, entity, id)
    }, machine)
    const team = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(entity))
    return {
      receiver: (row) => receiver(row.id),
      recheckReceiver: async (permit) => sameVmReceiverPermit(permit, await receiver(permit.machine)),
      authorize: async (row, p, proof, services) => {
        try {
          const connection = vmApiConnection(this.env)
          const driver = connection && row.network ? await this.driverFor(row) : null
          const found = driver ? await driver.peek(row.provider_name) : null
          if (!connection || !row.network || !found || found.tag.cmux_next_team !== entity || found.tag.cmux_next_machine !== row.id) {
            return { ok: false, code: "auth.forbidden", message: "no matching owned network allocation" }
          }
          return await team.authorizeCloudDial(entity, p, { vm: found.id, origin: connection.origin, network: row.network }, proof, services)
        } catch { return { ok: false, code: "owner.unreachable", message: "current network authorization is unavailable" } }
      },
      recheck: (p, permit) => vmApiConnection(this.env)?.origin === permit.origin
        ? team.recheckCloudDial(entity, p, permit).catch(() => false) : Promise.resolve(false)
    }
  }

  /**
   * cx-kvmz, RPC from POST /v1/cloud/machines/{machine}/acpmux/keyed-start and person-holds
   * (cloud-acpmux.ts): NOT ops. No submit, no op-log row, no ledger row, no param kept; the audit
   * row holds {action, machine, who, at, outcome} (cloud-acpmux-do.ts).
   */
  async acpmuxKeyedStart(entity: string, principal: Principal, machine: string, keyLine: Uint8Array): Promise<AcpmuxReply<{ personInstance: string }>> {
    const host = this.acpmuxHost(entity)
    if (!host) return (keyLine.fill(0), { ok: false, refusal: "not_found" })
    return acpmuxKeyedStartOn(host, principal, machine, keyLine)
  }

  async acpmuxPersonHolds(entity: string, principal: Principal, machine: string, nonce: string): Promise<AcpmuxReply<{ instance: string; proof: string }>> {
    const host = this.acpmuxHost(entity)
    return host ? acpmuxPersonHoldsOn(host, principal, machine, nonce) : { ok: false, refusal: "not_found" }
  }

  /**
   * Org workflows (plans/cmux-next/org-workflows-DESIGN.md): one machine or agent step of an
   * automation run of this team, from AutomationRunWorkflow. NOT an op: the run's own journal
   * (the Workflow's durable step) is the record. The machine must be a running machine of THIS
   * team: the object is per team, so another team's machine id is not found. Only a run charged
   * to the machine's creator may use it (a teammate's automation cannot run commands, with root,
   * on someone else's machine). No answer carries a provider error; stdout and stderr go back to
   * the run only.
   */
  automationExec(entity: string, user: string | null, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply> {
    // Only the machine's creator, while still a member: a teammate's automation never runs on it.
    return this.guestExec(entity, machine, (row) => (user !== null && row.creator === user ? this.mayUseMachines(entity, user) : Promise.resolve(false)), command, stdin, timeoutMs, { action: "automation.exec", who: `automation:${entity}` })
  }

  /**
   * The exec and file routes (cloud-machine-guest.ts, classic /api/vm's shapes): one command, as sent
   * (the route wraps it for the work user or runs it as root), on a machine of this team, for a person
   * who may use the team's machines now. Classic /api/vm lets any member of the owning team do the
   * same, so this is not creator-only; the link's owner answer (vm_kind) is a stricter rule of its own.
   * NOT an op. Another team's machine is not found; a member who left is forbidden.
   */
  ownerExec(entity: string, user: string, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply> {
    return this.guestExec(entity, machine, () => this.mayUseMachines(entity, user), command, stdin, timeoutMs, { action: "owner.exec", who: `platform:${user}` })
  }

  /** The personal team, or a member with team.resources now and no departure heard during the read. */
  private async mayUseMachines(entity: string, user: string): Promise<boolean> {
    if (entity === personalTeamIdFor(user)) return true
    const started = Date.now()
    const member = await this.creatorIsMember(entity, user).catch(() => false)
    return member && (this.leftAt.get(user) ?? -1) < started
  }

  private async guestExec(entity: string, machine: string, allowed: (row: MachineRow) => Promise<boolean>, command: string, stdin: Uint8Array | null, timeoutMs: number, audit: { action: string; who: string }): Promise<MachineExecReply> {
    if (!this.isBound(entity)) return { ok: false, refusal: "not_found" }
    const row = this.bind(entity).rows.get<MachineRow>(TABLE_MACHINE, machine)?.row
    if (!row) return { ok: false, refusal: "not_found" }
    if (!(await allowed(row))) return { ok: false, refusal: "forbidden" }
    if (row.status !== "running") return { ok: false, refusal: "not_running" }
    const driver = await Promise.resolve().then(() => this.driverFor(row)).catch(() => null)
    if (!driver) return { ok: false, refusal: "provider_failed" }
    // An answer too large to read is final: the same command answers the same way, so never "retry".
    const r = await driver.execStdin(row.provider_name, { team: entity, machine: row.id }, command, stdin, timeoutMs).catch((error: unknown) =>
      error instanceof DriverError && error.code === "cloud.exec.output_limit" ? ("output_limit" as const) : null
    )
    if (r === "output_limit") {
      this.audit.record({ action: audit.action, machine, who: audit.who, at: Date.now(), outcome: "output_limit" })
      return { ok: false, refusal: "output_limit" }
    }
    // Never the command or its stdin (a credential or a file's content may be on it).
    this.audit.record({ action: audit.action, machine, who: audit.who, at: Date.now(), outcome: r ? `exit ${r.exitCode}` : "provider_failed" })
    return r ? { ok: true, exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr } : { ok: false, refusal: "provider_failed" }
  }

  /**
   * RPC from POST /v1/cloud/machines/{machine}/client-session (cloud-client-session.ts): NOT an op.
   * No submit, no event, no ledger row; the audit row holds who, the machine, the user and the
   * expiry, never the token.
   */
  async mintClientSession(entity: string, principal: Principal, machine: string, ttlSeconds: number): Promise<ClientSessionReply> {
    if (principal.team !== entity) return { ok: false, refusal: "forbidden" }
    if (!this.isBound(entity)) return { ok: false, refusal: "not_found" }
    const rows = this.bind(entity).rows
    const limit = this.env.CLOUD_MUTATION_LIMIT
    return mintClientSessionOn(
      {
        team: entity,
        machine: (id) => rows.get<MachineRow>(TABLE_MACHINE, id)?.row,
        member: async (user, since) => {
          if (entity === personalTeamIdFor(user)) return true
          return (await this.creatorIsMember(entity, user).catch(() => false)) && (this.leftAt.get(user) ?? -1) < since
        },
        plan: async (p) => {
          await this.entitlements.refresh(entity, p)
          return teamPlan(this.testUnset.has("CLOUD_ALLOWED_TEAMS") ? { ...this.config, allowedTeams: new Set() } : this.config, entity) !== null
        },
        limit: async (user) => !limit || (await limit.limit({ key: `cloud-client-session:${user}` })).success,
        driver: (row) => Promise.resolve(this.driverFor(row)),
        identities: this.clientIdentityStore(),
        retryLater: () => this.retryClientIdentities(),
        audit: (e) => this.audit.record(e),
        now: () => Date.now() + this.skewMs,
        inflight: this.clientInflight
      },
      principal,
      machine,
      ttlSeconds
    )
  }
  private readonly clientInflight = new Map<string, Promise<unknown>>()
  private clientIdentities: ClientIdentityStore | null = null
  private clientIdentityStore(): ClientIdentityStore {
    return (this.clientIdentities ??= new ClientIdentityStore(this.sqlStore))
  }

  /** A retired identity's delete failed: try again in an hour, unless an earlier alarm is already set. */
  private retryClientIdentities(): void {
    const at = Date.now() + 3_600_000
    void this.ctx.storage.getAlarm().then((t) => (t === null || t > at ? this.ctx.storage.setAlarm(at) : undefined))
  }

  /** Retires gone machines' identities and deletes retired ones; only for a team that ever minted one. */
  private hasClientIdentities(): boolean {
    return this.clientIdentities !== null || this.sqlStore.exec<{ n: number }>(`SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'cloud_client_identity'`)[0]?.n === 1
  }

  protected override async sweepClientIdentities(now: number, first: ReadonlyArray<string> = []): Promise<void> {
    if (!this.hasClientIdentities()) return
    const entity = this.boundEntity()
    if (!entity || !this.isBound(entity)) return
    const rows = this.bind(entity).rows
    const driver = await Promise.resolve(this.driverFor({ transport: "direct" }, "cleanup")).catch(() => null)
    if (!driver) {
      // No provider right now: whatever waits for its delete is tried again later.
      if (this.clientIdentityStore().pending()) this.retryClientIdentities()
      return
    }
    if (await sweepClientIdentities(this.clientIdentityStore(), (id) => rows.get<MachineRow>(TABLE_MACHINE, id)?.row, driver, now, 10, first)) this.retryClientIdentities()
  }

  /**
   * The platform Worker's environment setups (PlatformMachines, platform-machines.ts) for `user` in this
   * team: boot, exec, snapshot and delete through the person's own ops (cloud-platform.ts). No public
   * route reaches it; only a Worker bound to PlatformMachines does.
   */
  async platformMachine(entity: string, user: string, call: PlatformCall, recoveryOnly = false): Promise<PlatformReply> {
    return platformCall(this.platformHost(entity), user, call, recoveryOnly)
  }

  private readonly platformOperations = new PlatformOperations(this.sqlStore)
  private platformHost(entity: string): PlatformHost {
    const rows = () => (this.isBound(entity) ? this.bind(entity).rows : undefined)
    const now = () => Date.now() + this.skewMs
    return {
      team: entity,
      operations: this.platformOperations,
      get now() { return now() },
      providerInfo: () => ({ protocolVersion: 1, provider: "freestyle", region: "global", available: this.env.PLATFORM_MACHINES === "on" && (this.env.CLOUD_VM_TRANSPORT === undefined || this.env.CLOUD_VM_TRANSPORT === "direct") && directCloudProvider(this.env).id === "freestyle" && cloudConfig(this.env).image !== null, shapeSelection: "grow-to-fit", minimumShape: null, memoryPause: true, fork: true }),
      arm: async (at) => {
        this.bind(entity)
        const realAt = Math.max(Date.now(), at - this.skewMs)
        const prior = await this.ctx.storage.getAlarm()
        if (prior === null || prior > realAt) await this.ctx.storage.setAlarm(realAt)
      },
      // A shared team: a member with team.resources now, and no departure heard during the read (as automationExec).
      mayUse: async (u) => {
        const started = Date.now()
        return entity === personalTeamIdFor(u) || ((await this.creatorIsMember(entity, u)) && (this.leftAt.get(u) ?? -1) < started)
      },
      submit: (p, f) => this.submit(entity, p, f),
      machine: (id) => rows()?.get<MachineRow>(TABLE_MACHINE, id)?.row,
      changing: (id) => this.isBound(entity) && Object.values(this.bind(entity).currentState.pending).some((e) => e.machine === id),
      resources: async (row) => {
        const driver = await Promise.resolve().then(() => this.driverFor(row)).catch(() => null)
        const r = driver ? await driver.resourcesOf(row.provider_name, { team: entity, machine: row.id }).catch(() => null) : null
        return r ? platformShape({ cpu: r.cpu, memory_mb: r.memory, disk_mb: r.storage }) : null
      },
      ledger: (key) => rows()?.get<LedgerRow>(TABLE_LEDGER, key)?.row,
      snapshot: (id) => rows()?.get<SnapshotRow>(TABLE_SNAPSHOT, id)?.row,
      platformSnapshot: (u, id) => {
        const reader = rows()
        if (!reader) return undefined
        let after: number | undefined
        for (;;) {
          const page = reader.range<LedgerRow>(TABLE_LEDGER, { after, limit: 1000 })
          const creation = page.find((l) => l.row.op === "snapshot" && l.row.snapshot === id)
          if (creation) return creation.row.key.startsWith(`${PLATFORM_IDENTITY_PREFIX}${u}|platform-env:snapshot:`)
          if (page.length < 1000) return undefined
          after = page[page.length - 1]!.n!
        }
      },
      platformSnapshotDeleted: (u, id) => {
        const reader = rows()
        if (!reader) return false
        const prefix = `${PLATFORM_IDENTITY_PREFIX}${u}|platform-env:deleteSnapshot:${id}:`
        let after: number | undefined
        for (;;) {
          const page = reader.range<LedgerRow>(TABLE_LEDGER, { after, limit: 1000 })
          if (page.some((l) => l.row.op === "snapshot_delete" && l.row.state === "done" && l.row.snapshot === id && l.row.key.startsWith(prefix))) return true
          if (page.length < 1000) return false
          after = page[page.length - 1]!.n!
        }
      },
      tombstoned: (machine) => rows()?.get(TABLE_TOMBSTONE, machine) !== undefined,
      exec: async (row, command, stdin, timeoutMs) => {
        const driver = await Promise.resolve().then(() => this.driverFor(row)).catch(() => null)
        return driver ? driver.execStdin(row.provider_name, { team: entity, machine: row.id }, command, stdin, timeoutMs).catch((error: unknown) => {
          if (error instanceof DriverError && error.code === "cloud.exec.output_limit") throw error
          return null
        }) : null
      },
      audit: (e) => this.audit.record(e)
    }
  }

  protected override platformStartsAllowed(): boolean {
    const entity = this.boundEntity()
    return entity !== null && this.platformHost(entity).providerInfo().available
  }

  protected override nextWakeAt(state: CloudState, now: number): number | null {
    const core = super.nextWakeAt(state, now)
    const due = this.platformOperations.dueAt()
    if (due === null) return core
    const operation = due - this.skewMs
    return core === null ? operation : Math.min(core, operation)
  }

  protected override async onWake(now: number): Promise<void> {
    const entity = this.boundEntity()
    if (entity) {
      const host = this.platformHost(entity)
      await this.platformOperations.stopAllocations(host, now + this.skewMs)
    }
    await super.onWake(now)
    if (entity) await this.platformOperations.wake(this.platformHost(entity), now + this.skewMs)
  }

  private readonly acpmuxStarting = new Set<string>()
  /** null for an object nobody created (it is never created here). */
  private acpmuxHost(entity: string): AcpmuxHost | null {
    if (!this.isBound(entity)) return null
    const rows = this.bind(entity).rows
    return {
      team: entity,
      machine: (id) => rows.get<MachineRow>(TABLE_MACHINE, id)?.row,
      driver: (row) => this.driverFor(row),
      members: async (team, user) => {
        const stub = this.env.TEAM_DO.get(this.env.TEAM_DO.idFromName(team)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { member_count?: unknown; members?: Array<{ user?: unknown }> } }> }
        const r = await stub.readOp(team, { identity: `session:${user}`, kind: "session", user, team }, "team.members.list", { limit: 2 })
        if (!r.ok || typeof r.value?.member_count !== "number" || !Array.isArray(r.value.members)) return null
        return { count: r.value.member_count, users: r.value.members.map((m) => (typeof m.user === "string" ? m.user : "")) }
      },
      audit: (e) => this.audit.record(e),
      starting: this.acpmuxStarting
    }
  }

  /** The team's cloud.connectServices from its TeamDO (fail closed: a failed RPC fails the read). */
  private teamConnectServices(entity: string): Promise<ReadonlyArray<string>> {
    return this.teamCloudPolicy(entity).then((p) => p.connect_services)
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
    const driver = await this.driverFor(stored.row, "cleanup")
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
  async fakeControl(cmd: { snapshot_delete_refuse?: number; power_refuse?: number; vm_state?: { name: string; state: string }; image_size?: { cpu: number; memory: number; storage: number }; resize_partial?: number; resize_refuse?: number; power_then_fail?: number; fail_revokes?: number; link_keys?: string; unset?: ReadonlyArray<"CLOUD_API_ORIGIN" | "ENVIRONMENT_TAG" | "CLOUD_ALLOWED_TEAMS">; fail_next?: number; drop_results?: number; advance_ms?: number; delete_vm?: string; fail_list?: boolean; add_vm?: { name: string; team: string; machine: string }; edge_host?: string | null; auto_pause?: boolean | null; entitlements?: "on" | "off"; exec_build_exit?: number; exec_log?: string; guest_reply?: { exitCode: number; stdout: string; stderr: string } | null }) {
    if (this.env.ENVIRONMENT !== "test") throw new Error("fakeControl is test only")
    cloudDriver(this.env, this.sqlStore)
    if (cmd.entitlements !== undefined) this.entitlements.enabled = cmd.entitlements === "on"
    if (cmd.edge_host !== undefined) this.edge.testHost = cmd.edge_host
    if (cmd.unset) this.testUnset = new Set(cmd.unset)
    if (cmd.auto_pause !== undefined) this.testAutoPause = cmd.auto_pause
    if (cmd.link_keys !== undefined) this.testLinkKeys = cmd.link_keys
    if (cmd.fail_revokes !== undefined) this.failRevokes = cmd.fail_revokes
    if (cmd.snapshot_delete_refuse !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET snapshot_delete_refuse = ? WHERE id = 1`, cmd.snapshot_delete_refuse)
    if (cmd.power_refuse !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET power_refuse = ? WHERE id = 1`, cmd.power_refuse)
    if (cmd.vm_state) this.stateChecks.clear()
    if (cmd.vm_state) this.sqlStore.exec(`UPDATE cloud_fake_vm SET state = ? WHERE name = ?`, cmd.vm_state.state, cmd.vm_state.name)
    if (cmd.image_size) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET image_cpu = ?, image_memory = ?, image_storage = ? WHERE id = 1`, cmd.image_size.cpu, cmd.image_size.memory, cmd.image_size.storage)
    if (cmd.resize_partial !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET resize_partial = ? WHERE id = 1`, cmd.resize_partial)
    if (cmd.resize_refuse !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET resize_refuse = ? WHERE id = 1`, cmd.resize_refuse)
    if (cmd.power_then_fail !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET power_then_fail = ? WHERE id = 1`, cmd.power_then_fail)
    if (cmd.fail_next !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_next = ? WHERE id = 1`, cmd.fail_next)
    if (cmd.drop_results !== undefined) this.dropResults = cmd.drop_results
    if (cmd.exec_build_exit !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_guest SET build_exit = ? WHERE id = 1`, cmd.exec_build_exit)
    if (cmd.exec_log !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_guest SET log = ? WHERE id = 1`, cmd.exec_log)
    if (cmd.guest_reply !== undefined) this.sqlStore.exec(`INSERT OR REPLACE INTO cloud_fake_guest_reply (id, reply) VALUES (1, ?)`, cmd.guest_reply ? JSON.stringify(cmd.guest_reply) : null)
    if (cmd.fail_list !== undefined) this.sqlStore.exec(`UPDATE cloud_fake_ctl SET fail_list = ? WHERE id = 1`, cmd.fail_list ? 1 : 0)
    if (cmd.advance_ms !== undefined) this.skewMs += cmd.advance_ms
    if (cmd.delete_vm !== undefined) this.sqlStore.exec(`DELETE FROM cloud_fake_vm WHERE name = ?`, cmd.delete_vm)
    if (cmd.add_vm !== undefined) {
      const t = { cmux_next_team: cmd.add_vm.team, cmux_next_machine: cmd.add_vm.machine }
      this.sqlStore.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle) VALUES (?, ?, ?, NULL)`, cmd.add_vm.name, `fs-${cmd.add_vm.name}`, JSON.stringify(t))
    }
    const ctl = this.sqlStore.exec<{ creates: number; deletes: number; pauses: number; starts: number; resizes: number; state_reads: number; power_calls: number; snapshot_deletes: number }>(`SELECT creates, deletes, pauses, starts, resizes, state_reads, power_calls, snapshot_deletes FROM cloud_fake_ctl WHERE id = 1`)[0]!
    const vms = this.sqlStore.exec<{ name: string; id: string; idle: number | null; cpu: number; memory: number; snapshot: string | null }>(`SELECT name, id, idle, cpu, memory, snapshot FROM cloud_fake_vm ORDER BY name`).map((v) => ({ ...v, cpu: Number(v.cpu), memory: Number(v.memory) }))
    const snapshots = this.sqlStore.exec<{ slug: string; source: string }>(`SELECT slug, source FROM cloud_fake_snapshot ORDER BY slug`)
    const files = this.sqlStore.exec<{ vm: string; path: string; content: string; mode: number }>(`SELECT vm, path, content, mode FROM cloud_fake_file ORDER BY vm`).map((f) => ({ ...f, mode: Number(f.mode) }))
    const tls = this.sqlStore.exec<{ vm: string; domain: string; rule: string }>(`SELECT vm, domain, rule FROM cloud_fake_tls ORDER BY vm`).map((r) => ({ vm: r.vm, domain: r.domain, rule: JSON.parse(r.rule) as unknown }))
    const execs = this.sqlStore.exec<{ vm: string; kind: string }>(`SELECT vm, kind FROM cloud_fake_exec ORDER BY n`).map((e) => ({ vm: e.vm, kind: e.kind }))
    const guest_calls = this.sqlStore.exec<{ command: string; stdin: string | null }>(`SELECT command, stdin FROM cloud_fake_guest_call ORDER BY n`).map((c) => ({ command: c.command, stdin: c.stdin }))
    return { execs, guest_calls, tls, files, audit: this.audit.list(), creates: ctl.creates, deletes: ctl.deletes, pauses: Number(ctl.pauses), starts: Number(ctl.starts), resizes: Number(ctl.resizes), state_reads: Number(ctl.state_reads), power_calls: Number(ctl.power_calls), snapshot_deletes: Number(ctl.snapshot_deletes), vms, pending: Object.keys(this.boundEngine?.currentState.pending ?? {}).length, suspects: this.sweep.suspects(), sweep_at: this.sweep.at(), vm_revokes: this.vmRevokes.pending(), snapshots, now: Date.now() + this.skewMs }
  }
}
