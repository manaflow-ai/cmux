import type { Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import type { TeamState } from "../src/domains/team.ts"
import { machineRefused } from "../src/machine-installs.ts"
import { teamRead } from "../src/team-reads.ts"

/**
 * `team_vm.accounts` (team-vm-plan.md S4, bead cx-embr): the team VM's reconciler reads, as the VM's own
 * install, the Linux users of the team's current members and the principals each user accepts.
 */
const TEAM = "team_00000000000000000181"
const OWNER = "user_00000000000000000181"
const MEMBER = "user_00000000000000000182"
const GONE = "user_00000000000000000183"
const state = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "Acme" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "Lawrence Chen" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "Ada Q" }
  },
  hosts: {},
  // GONE left the team: its account (and UID block) stays allocated, never reused.
  vm_accounts: { [OWNER]: { name: "lawrence", uid: 20000 }, [GONE]: { name: "grace", uid: 20004 }, [MEMBER]: { name: "ada", uid: 20008 } },
  vm_next_uid: 20012
})
const teamVm: Principal = { identity: "install:inst_00000000000000000181", kind: "install", user: OWNER, team: TEAM, install: "inst_00000000000000000181", install_kind: "team-vm" }
const ownerSession: Principal = { identity: `user:${OWNER}`, kind: "session", user: OWNER, team: TEAM }
const memberSession: Principal = { identity: `user:${MEMBER}`, kind: "session", user: MEMBER, team: TEAM }
const ownerClient: Principal = { identity: "install:inst_00000000000000000182", kind: "install", user: OWNER, team: TEAM, install: "inst_00000000000000000182", install_kind: "mac" }

describe("team_vm.accounts", () => {
  it("lists each current member's person and agents users with their UIDs, sorted by UID", () => {
    const r = teamRead(state(), "team_vm.accounts", {}, teamVm)
    expect(r).toMatchObject({ ok: true })
    expect(r.ok && r.value).toEqual({
      team: TEAM,
      users: [
        { user: "lawrence", uid: 20000, class: "human", principals: ["lawrence"] },
        { user: "lawrence-agents", uid: 20002, class: "agent", principals: ["lawrence-agents"] },
        { user: "ada", uid: 20008, class: "human", principals: ["ada"] },
        { user: "ada-agents", uid: 20010, class: "agent", principals: ["ada-agents"] }
      ]
    })
  })

  it("is for the team VM and the team's owners and admins only (deny by default)", () => {
    expect(teamRead(state(), "team_vm.accounts", {}, ownerSession)).toMatchObject({ ok: true })
    expect(teamRead(state(), "team_vm.accounts", {}, memberSession)).toMatchObject({ ok: false, code: "auth.forbidden" })
    // An owner's ordinary client install is not the team VM.
    expect(teamRead(state(), "team_vm.accounts", {}, ownerClient)).toMatchObject({ ok: false, code: "auth.forbidden" })
    expect(machineRefused("team-vm", "team_vm.accounts")).toBe(false)
    expect(machineRefused("vm", "team_vm.accounts")).toBe(true)
  })

  it("a team with no allocated account answers an empty list", () => {
    const s = { ...state(), vm_accounts: {} }
    expect(teamRead(s, "team_vm.accounts", {}, teamVm)).toMatchObject({ ok: true, value: { team: TEAM, users: [] } })
  })
})
