import { describe, expect, it } from "bun:test"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { TeamVmCard, type TeamVmCardProps } from "../src/lib/team-vm-card.tsx"
import { initialCardState, reduceCard, taintBadge, teamVmRequest, type CardState, type TeamVmView } from "../src/lib/team-vm.ts"
import { teamVmErrorText, teamVmText } from "../src/lib/team-vm-strings.ts"

const NOW = 1_800_000_000_000

const view = (over: Partial<TeamVmView> = {}): TeamVmView => ({
  team: "team_1",
  status: "running",
  vm: "vm_cur",
  epoch: 4,
  taint: null,
  retired: [],
  ...over
})

const tainted = (over: Partial<NonNullable<TeamVmView["taint"]>> = {}) =>
  view({ taint: { epoch: 4, at: NOW, users: ["usr_gone_1", "usr_gone_2"], accepted_by: null, accepted_at: null, ...over } })

const retired = (state: "pausing" | "paused" = "paused") => ({ vm: "vm_old_3", epoch: 3, state, at: NOW, by: "usr_owner", tainted_by: ["usr_gone_1"] })

const render = (props: Partial<TeamVmCardProps> = {}) =>
  renderToStaticMarkup(
    createElement(TeamVmCard, {
      view: view(),
      role: "member",
      locale: "en",
      state: initialCardState,
      onOpen: () => {},
      onCancel: () => {},
      onFilesCopied: () => {},
      onConfirm: () => {},
      ...props
    })
  )

const open = (s: CardState, kind: "accept" | "rebuild" | "delete", vm?: string) => reduceCard(s, { t: "open", kind, vm })

describe("team VM taint badge", () => {
  it("is clean without a taint, tainted until accepted, then accepted", () => {
    expect(taintBadge(view())).toBe("clean")
    expect(taintBadge(tainted())).toBe("tainted")
    expect(taintBadge(tainted({ accepted_by: "usr_owner", accepted_at: NOW }))).toBe("accepted")
  })
  it("shows every member the badge and the removed members, without owner actions", () => {
    const html = render({ view: tainted(), role: "member" })
    expect(html).toContain('data-taint="tainted"')
    expect(html).toContain("usr_gone_1")
    expect(html).toContain("usr_gone_2")
    expect(html).not.toContain(">Accept the risk<")
    expect(html).not.toContain(">Rebuild from snapshot<")
    expect(html).toContain("Ask a team owner or admin")
    expect(render({ role: "member" })).toContain('data-taint="clean"')
  })
  it("offers owners and admins Accept and Rebuild on a tainted VM", () => {
    for (const role of ["owner", "admin"] as const) {
      const html = render({ view: tainted(), role })
      expect(html).toContain(">Accept the risk<")
      expect(html).toContain(">Rebuild from snapshot<")
    }
    // Accepted: no second accept, rebuild stays.
    const accepted = render({ view: tainted({ accepted_by: "usr_owner", accepted_at: NOW }), role: "owner" })
    expect(accepted).toContain('data-taint="accepted"')
    expect(accepted).not.toContain(">Accept the risk<")
    expect(accepted).toContain(">Rebuild from snapshot<")
    // No VM yet: nothing to rebuild.
    expect(render({ view: view({ vm: null, status: "none", epoch: 0 }), role: "owner" })).not.toContain(">Rebuild from snapshot<")
  })
})

describe("team VM requests", () => {
  it("accepts exactly the tainted epoch and the removed members that status showed", () => {
    const s = open(initialCardState, "accept")
    expect(teamVmRequest(tainted(), s.dialog)).toEqual({ op: "team_vm.taint.accept", params: { epoch: 4, users: ["usr_gone_1", "usr_gone_2"] } })
    expect(teamVmRequest(view(), s.dialog)).toBeNull()
    expect(teamVmRequest(tainted({ accepted_by: "usr_owner", accepted_at: NOW }), s.dialog)).toBeNull()
  })
  it("rebuilds the current epoch", () => {
    expect(teamVmRequest(tainted(), open(initialCardState, "rebuild").dialog)).toEqual({ op: "team_vm.rebuild", params: { epoch: 4 } })
    expect(teamVmRequest(view({ vm: null }), open(initialCardState, "rebuild").dialog)).toBeNull()
  })
  it("deletes a retired VM only after the files-copied checkbox, and then sends files_copied: true", () => {
    const v = view({ retired: [retired()] })
    const s = open(initialCardState, "delete", "vm_old_3")
    expect(teamVmRequest(v, s.dialog)).toBeNull()
    const checked = reduceCard(s, { t: "files_copied", value: true })
    expect(teamVmRequest(v, checked.dialog)).toEqual({ op: "team_vm.retired.delete", params: { vm: "vm_old_3", files_copied: true } })
    expect(teamVmRequest(v, reduceCard(checked, { t: "files_copied", value: false }).dialog)).toBeNull()
    // A VM still pausing, or one that is not in the list, is never deleted.
    expect(teamVmRequest(view({ retired: [retired("pausing")] }), checked.dialog)).toBeNull()
    expect(teamVmRequest(view(), checked.dialog)).toBeNull()
  })
  it("closes the dialog on success and keeps it open with the error code on failure", () => {
    const sent = reduceCard(open(initialCardState, "rebuild"), { t: "sent" })
    expect(sent.busy).toBe(true)
    expect(reduceCard(sent, { t: "done", error: null })).toEqual(initialCardState)
    const failed = reduceCard(sent, { t: "done", error: { code: "team_vm.retired_full", message: "delete a retired team VM first" } })
    expect(failed.busy).toBe(false)
    expect(failed.dialog?.kind).toBe("rebuild")
    expect(failed.error?.code).toBe("team_vm.retired_full")
    // Opening another dialog clears the old error and the checkbox.
    const other = open(failed, "delete", "vm_old_3")
    expect(other.error).toBeNull()
    expect(other.dialog).toEqual({ kind: "delete", vm: "vm_old_3", filesCopied: false })
  })
})

describe("team VM confirms", () => {
  it("rebuild confirm says /srv/team is not carried over and stays on the paused old VM", () => {
    const html = render({ view: tainted(), role: "owner", state: open(initialCardState, "rebuild") })
    expect(html).toContain('role="alertdialog"')
    expect(html).toContain("/srv/team")
    expect(html).toContain("NOT carried to the new VM")
    expect(html).toContain("paused old VM")
    expect(html).toContain("before you delete")
    expect(html).toContain("epoch 5")
  })
  it("delete confirm needs the checkbox before its button works", () => {
    const v = view({ retired: [retired()] })
    const s = open(initialCardState, "delete", "vm_old_3")
    const unchecked = render({ view: v, role: "owner", state: s })
    expect(unchecked).toContain("I copied the team files off this VM")
    expect(unchecked).toMatch(/<button[^>]*data-confirm="delete"[^>]*disabled=""/)
    const checked = render({ view: v, role: "owner", state: reduceCard(s, { t: "files_copied", value: true }) })
    expect(checked).not.toMatch(/<button[^>]*data-confirm="delete"[^>]*disabled=""/)
    expect(checked).toContain('checked=""')
  })
  it("lists retired VMs for everyone, with Delete only for owners and admins and only once paused", () => {
    const v = view({ retired: [retired(), { ...retired("pausing"), vm: "vm_old_2", epoch: 2 }] })
    const member = render({ view: v, role: "member" })
    expect(member).toContain("vm_old_3")
    expect(member).toContain("vm_old_2")
    expect(member).not.toContain('data-delete="')
    const owner = render({ view: v, role: "owner" })
    expect(owner).toContain('data-delete="vm_old_3"')
    expect(owner).not.toContain('data-delete="vm_old_2"')
  })
  it("shows a failed action's error code with a localized message", () => {
    const failed = reduceCard(reduceCard(open(initialCardState, "delete", "vm_old_3"), { t: "sent" }), { t: "done", error: { code: "team_vm.retired_files_unconfirmed", message: "x" } })
    const html = render({ view: view({ retired: [retired()] }), role: "owner", state: failed })
    expect(html).toContain("team_vm.retired_files_unconfirmed")
    expect(html).toContain(teamVmErrorText("en", "team_vm.retired_files_unconfirmed"))
    const ja = render({ view: view({ retired: [retired()] }), role: "owner", state: failed, locale: "ja" })
    expect(ja).toContain(teamVmErrorText("ja", "team_vm.retired_files_unconfirmed"))
  })
})

describe("team VM strings", () => {
  it("has a distinct Japanese text for every key and every known error", () => {
    expect(teamVmText("ja", "action.rebuild")).not.toBe(teamVmText("en", "action.rebuild"))
    for (const code of ["team_vm.retired_files_unconfirmed", "team_vm.stale_taint", "team_vm.not_tainted", "team_vm.stale_epoch", "team_vm.retired_full", "team_vm.in_use", "auth.forbidden"]) {
      expect(teamVmErrorText("en", code)).not.toBe(teamVmErrorText("en", "some.unknown"))
      expect(teamVmErrorText("ja", code)).not.toBe(teamVmErrorText("en", code))
    }
  })
  it("renders the card in Japanese", () => {
    const html = render({ view: tainted(), role: "owner", locale: "ja" })
    expect(html).toContain(teamVmText("ja", "action.rebuild"))
    expect(html).not.toContain(">Rebuild from snapshot<")
  })
})
