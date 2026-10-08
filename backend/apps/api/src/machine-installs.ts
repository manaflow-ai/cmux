/**
 * Machine installs: the key of a cloud machine, never a person's client. Each kind may call only
 * its own machine's ops and has no socket, Home access, chief token or UserDO path (review P1 for
 * kind `vm`, 2026-10-08 review of the team VM bind for kind `team-vm`).
 *
 * - `vm`: a personal Cloud machine (cloud-vm.ts): the cloud.vm.* ops for its own machine.
 * - `team-vm`: a team VM (team-vm-bind-run.ts, vm-image.md 6b): its team's SSH CA and KRL, its
 *   VM status and the team journal (TeamVmDO admits only the epoch's bound install there).
 */
export const TEAM_VM_INSTALL_OPS: ReadonlySet<string> = new Set(["team_vm.ssh_ca", "team_vm.status", "team_vm.journal.append", "team_vm.journal.high_water", "team_vm.journal.read"])

export const isMachineInstallKind = (kind: string | undefined): boolean => kind === "vm" || kind === "team-vm"

/** True when a machine install may not call `op`. */
export const machineRefused = (kind: string | undefined, op: string): boolean =>
  kind === "vm" ? !op.startsWith("cloud.vm.") : kind === "team-vm" ? !TEAM_VM_INSTALL_OPS.has(op) : false
