import type { OwnerFrame, Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"
import type { TeamVmState } from "./domains/team-vm.ts"
import { DriverError, type TeamVmDriver } from "./team-vm-driver.ts"
import type { SqlStore } from "@cmux/ownership"
import { checkProof, commitCommand, enrollCommand, EXEC_TIMEOUT_MS, parseProof, TeamVmBinds, vmEnvName } from "./team-vm-bind.ts"

/** What one bind pass needs from TeamVmDO (and what tests replace). */
export interface BindDeps {
  readonly env: Env
  readonly binds: TeamVmBinds
  driver(): TeamVmDriver | null
  state(): TeamVmState | undefined
  submitSystem(op: string, params: unknown, key: string): SubmitResult
  now(): number
}

type Jwk = { kty: string; crv: string; x: string; y: string }

/** The bind is on only where TEAM_VM_BIND_ENABLED=1 (development, staging and tests until the backend lead's review). */
export const bindEnabled = (env: Pick<Env, "TEAM_VM_BIND_ENABLED">) => env.TEAM_VM_BIND_ENABLED === "1"

/** Does the record still name this (team, epoch, vm)? Re-read after every await. */
const same = (s: TeamVmState | undefined, team: string, epoch: number, vm: string) => s?.team === team && s.epoch === epoch && s.vm === vm

const log = (msg: string, fields: Record<string, unknown>) => console.log(JSON.stringify({ msg, ...fields }))

/** The team's owner: the user whose UserDO holds the team VM's install (stable while members come and go). */
const teamOwner = async (env: Env, team: string): Promise<string | null> => {
  const stub = env.TEAM_DO.get(env.TEAM_DO.idFromName(team)) as unknown as { teamVmInstallOwner(entity: string): Promise<string | null> }
  return stub.teamVmInstallOwner(team)
}

/**
 * Registers the VM's key as a server install of the team's owner: kind team-vm, bound to the team
 * (its tokens name the team), grant read + mutate-own, and every entry point refuses it except
 * the team VM ops (machine-installs.ts). Keyed by team, epoch and key, so a retried bind gets the
 * same install.
 */
const registerInstall = async (env: Env, a: { owner: string; team: string; epoch: number; vm: string; jwk: Jwk }): Promise<{ ok: true; id: string } | { ok: false; code: string }> => {
  const stub = env.USER_DO.get(env.USER_DO.idFromName(a.owner)) as unknown as { submit(e: string, p: Principal, f: unknown): Promise<SubmitResult> }
  const server: Principal = { identity: `system:team-vm:${a.team}`, kind: "system", user: a.owner, team: a.team, sso_team: a.team }
  const frame = {
    t: "op",
    op: "install.register_server",
    params: { public_jwk: a.jwk, kind: "team-vm", name: "Team VM", device_name: a.vm.slice(0, 80), platform: "linux", bound_team: a.team },
    idempotency_key: `team-vm-install:${a.team}:${a.epoch}:${a.jwk.x}`,
    origin: "user"
  }
  const r = await stub.submit(a.owner, server, frame).catch(() => null)
  const f = r?.frames.find((x: OwnerFrame) => x.t === "result" || x.t === "reject") as { t: string; value?: { id: string }; code?: string } | undefined
  if (!f || f.t !== "result" || !f.value) return { ok: false, code: f?.code ?? "owner.unreachable" }
  return { ok: true, id: f.value.id }
}

const revokeInstall = async (env: Env, a: { owner: string; team: string; install: string; why: string }): Promise<boolean> => {
  const stub = env.USER_DO.get(env.USER_DO.idFromName(a.owner)) as unknown as { revokeByTeam(e: string, team: string, install: string, by: string, key: string): Promise<{ ok: boolean; code?: string }> }
  const r = await stub.revokeByTeam(a.owner, a.team, a.install, a.owner, `team-vm-revoke:${a.install}`).catch(() => ({ ok: false, code: "owner.unreachable" }))
  if (!r.ok && r.code === "selector.not_found") return true
  if (!r.ok) log("team vm install revoke failed", { team: a.team, install: a.install, why: a.why, code: r.code })
  return r.ok
}

/** Tells the bound VM its user and install (the second exec). Retried by the alarm until it lands. */
const commit = async (d: BindDeps, driver: TeamVmDriver, a: { team: string; epoch: number; vm: string; owner: string; install: string }): Promise<boolean> => {
  const cmd = commitCommand({ team: a.team, epoch: String(a.epoch), user: a.owner, install: a.install, api: d.env.CLOUD_API_ORIGIN ?? "", env: vmEnvName(d.env.ENVIRONMENT) })
  if (!cmd) {
    d.binds.failed(a.epoch, "team_vm.bind_no_api_origin", d.now())
    return false
  }
  const out = await driver.exec(a.vm, cmd, EXEC_TIMEOUT_MS).catch(() => null)
  if (!out || out.code !== 0) {
    d.binds.failed(a.epoch, "team_vm.bind_commit", d.now())
    return false
  }
  d.binds.markCommitted(a.epoch)
  d.binds.clearAttempts(a.epoch)
  return true
}

/** The installs of earlier epochs (a replaced or restored VM's key) lose their grant. */
const revokeStale = async (d: BindDeps, team: string, epoch: number) => {
  for (const old of d.binds.staleInstalls(epoch)) {
    if (await revokeInstall(d.env, { owner: old.owner, team, install: old.install, why: "epoch replaced" })) d.binds.markRevoked(old.epoch)
  }
}

/**
 * One bind pass for the record's current epoch (vm-image.md 6b). Fails closed: any mismatch leaves
 * the epoch unbound (the journal answers team_vm.not_bound) and the alarm retries with backoff.
 */
export const runTeamVmBind = async (d: BindDeps, at: number = d.now()): Promise<{ bound?: string; error?: string }> => {
  const s = d.state()
  if (!bindEnabled(d.env) || !s?.team) return {}
  // Earlier epochs' installs are revoked even while no VM runs (a deleted or replaced VM).
  if (!s.vm || s.status !== "running") {
    await revokeStale(d, s.team, s.epoch)
    return {}
  }
  const driver = d.driver()
  if (!driver) return {}
  const { team, epoch, vm } = s
  // Earlier epochs' installs (a replaced or restored VM's key) lose their grant first; a failed revoke is retried.
  await revokeStale(d, team, epoch)
  if (s.vm_install) {
    const rec = d.binds.installFor(epoch)
    if (rec && rec.install === s.vm_install && !rec.committed && d.binds.due(epoch, at)) await commit(d, driver, { team, epoch, vm, owner: rec.owner, install: rec.install })
    return {}
  }
  if (!d.binds.due(epoch, at)) return {}
  const fail = (code: string) => {
    // Replaces the pre-count below: one failed pass is one attempt.
    d.binds.note(epoch, code, d.now())
    log("team vm bind refused", { team, epoch, vm, code })
    return { error: code }
  }
  // Counted before the exec: a pass cut short (eviction) is retried by the alarm after the backoff.
  d.binds.failed(epoch, "team_vm.bind_running", d.now())
  const nonce = d.binds.mint(epoch, vm, d.now())
  const cmd = enrollCommand(team, epoch, nonce)
  if (!cmd) return fail("team_vm.bind_invalid")
  let out: { code: number; stdout: string }
  try {
    out = await driver.exec(vm, cmd, EXEC_TIMEOUT_MS)
  } catch (e) {
    d.binds.consume(nonce, epoch, vm, d.now())
    return fail(e instanceof DriverError ? e.code : "team_vm.bind_exec")
  }
  if (!same(d.state(), team, epoch, vm)) {
    d.binds.consume(nonce, epoch, vm, d.now())
    return { error: "team_vm.stale_epoch" }
  }
  const proof = out.code === 0 ? parseProof(out.stdout) : null
  if (!proof) {
    d.binds.consume(nonce, epoch, vm, d.now())
    return fail(out.code === 0 ? "team_vm.bind_proof" : "team_vm.bind_exec")
  }
  const checked = await checkProof(d.binds, proof, { team, epoch, vm, nonce }, d.now())
  if (!checked.ok) return fail(checked.code)
  if (!same(d.state(), team, epoch, vm)) return { error: "team_vm.stale_epoch" }
  const owner = await teamOwner(d.env, team).catch(() => null)
  if (!owner) return fail("team_vm.bind_no_owner")
  const reg = await registerInstall(d.env, { owner, team, epoch, vm, jwk: proof.public_jwk })
  if (!reg.ok) return fail(reg.code)
  if (!same(d.state(), team, epoch, vm)) {
    await revokeInstall(d.env, { owner, team, install: reg.id, why: "epoch moved during bind" })
    return { error: "team_vm.stale_epoch" }
  }
  const r = d.submitSystem("team_vm.bind_install", { install: reg.id, epoch, vm }, `bind_install:${epoch}:${reg.id}`)
  const reply = r.frames.find((f) => f.t === "result" || f.t === "reject")
  if (!reply) return fail("owner.unreachable")
  if (reply.t !== "result") {
    // An explicit refusal (another epoch or another install bound): this install never speaks for the VM.
    // An unknown outcome is retried with the same key instead, so it reuses this live install.
    await revokeInstall(d.env, { owner, team, install: reg.id, why: "bind_install refused" })
    return fail(reply.t === "reject" ? reply.code : "owner.unreachable")
  }
  d.binds.recordInstall(epoch, reg.id, owner)
  log("team vm bound", { team, epoch, vm, install: reg.id })
  await commit(d, driver, { team, epoch, vm, owner, install: reg.id })
  return { bound: reg.id }
}

/** TeamVmDO's bind driver: one pass at a time, and the alarm time of its next retry. */
export class BindRunner {
  readonly binds: TeamVmBinds
  private running: Promise<unknown> | null = null
  constructor(
    sql: SqlStore,
    private readonly deps: Omit<BindDeps, "binds">,
    private readonly afterPass: () => void
  ) {
    this.binds = new TeamVmBinds(sql)
  }

  /** `at`: the time the backoff is checked against (the alarm's wake time). */
  pass(at?: number): Promise<unknown> {
    if (!this.running) {
      this.running = runTeamVmBind({ ...this.deps, binds: this.binds }, at)
        .catch((e) => console.warn(JSON.stringify({ msg: "team vm bind pass failed", error: String(e) })))
        .finally(() => {
          this.running = null
          this.afterPass()
        })
    }
    return this.running
  }

  /** The next retry while the running VM's epoch is unbound or its commit has not landed. */
  wakeAt(state: TeamVmState): number | null {
    if (!bindEnabled(this.deps.env)) return null
    // A stale install whose revoke failed is retried even when no VM runs.
    if (this.binds.staleInstalls(state.epoch).length > 0) return this.binds.nextRetry(state.epoch) ?? Date.now() + 60_000
    if (!state.vm || state.status !== "running") return null
    if (state.vm_install && this.binds.installFor(state.epoch)?.committed !== false) return null
    return this.binds.nextRetry(state.epoch)
  }
}
