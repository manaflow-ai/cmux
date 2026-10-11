/**
 * The team VM card on the Team page (cx-hnj9). `team_vm.status` (packages/protocol/src/team-vm-ops.ts
 * TeamVmView) carries the taint of the current epoch (cx-q4f3) and the VMs a rebuild retired. Every
 * member sees the taint badge; owners and admins accept the risk, rebuild from the base snapshot, or
 * delete a retired VM. A rebuild does not carry /srv/team, so a delete sends `files_copied: true`
 * only after the person ticked "I copied the team files off this VM" (cx-zr9i). Download (cx-lyvg)
 * exports a paused retired VM's /srv/team as a tar (team_vm.retired.export); the checkbox stays
 * manual, because only the person can check that the archive opened.
 */

export type TeamRole = "owner" | "admin" | "member"

export interface TeamVmTaint {
  readonly epoch: number
  readonly at: number
  readonly users: ReadonlyArray<string>
  readonly accepted_by: string | null
  readonly accepted_at: number | null
}

export interface TeamVmRetired {
  readonly vm: string
  readonly epoch: number
  readonly state: "pausing" | "paused"
  readonly at: number
  readonly by: string
  readonly tainted_by: ReadonlyArray<string>
}

/** The part of TeamVmView the card reads. */
export interface TeamVmView {
  readonly team: string
  readonly status: "none" | "provisioning" | "starting" | "running" | "paused" | "failed"
  readonly vm: string | null
  readonly epoch: number
  readonly taint: TeamVmTaint | null
  readonly retired: ReadonlyArray<TeamVmRetired>
}

/** The API keeps at most this many retired VMs; a rebuild beyond it answers team_vm.retired_full. */
export const MAX_RETIRED = 3

export type TaintBadge = "clean" | "tainted" | "accepted"

export const taintBadge = (view: TeamVmView): TaintBadge => (!view.taint ? "clean" : view.taint.accepted_by ? "accepted" : "tainted")

export const canManageTeamVm = (role: TeamRole | null) => role === "owner" || role === "admin"

export const roleOf = (role: unknown): TeamRole | null => (role === "owner" || role === "admin" || role === "member" ? role : null)

export type Dialog = { readonly kind: "accept" } | { readonly kind: "rebuild" } | { readonly kind: "delete"; readonly vm: string; readonly filesCopied: boolean }

export interface CardError {
  readonly code: string
  readonly message: string
}

/** The last team files download of this page: preparing, started in the browser, or failed. */
export interface DownloadState {
  readonly vm: string
  readonly phase: "busy" | "started" | "failed"
  readonly error: CardError | null
  /** Entries the archive does not hold (symlinks, special files). */
  readonly skipped: number
}

export interface CardState {
  readonly dialog: Dialog | null
  readonly busy: boolean
  readonly error: CardError | null
  readonly download: DownloadState | null
}

export const initialCardState: CardState = { dialog: null, busy: false, error: null, download: null }

export type CardEvent =
  | { readonly t: "open"; readonly kind: Dialog["kind"]; readonly vm?: string }
  | { readonly t: "cancel" }
  | { readonly t: "files_copied"; readonly value: boolean }
  | { readonly t: "sent" }
  | { readonly t: "done"; readonly error: CardError | null }
  | { readonly t: "download"; readonly vm: string }
  | { readonly t: "download_done"; readonly vm: string; readonly error: CardError | null; readonly skipped: number }

/** The card's dialog state. A failed op keeps its dialog open with the error; a success closes it. */
export const reduceCard = (s: CardState, e: CardEvent): CardState => {
  switch (e.t) {
    case "open":
      if (s.busy) return s
      if (e.kind === "delete") return e.vm ? { dialog: { kind: "delete", vm: e.vm, filesCopied: false }, busy: false, error: null, download: s.download } : s
      return { dialog: { kind: e.kind }, busy: false, error: null, download: s.download }
    case "cancel":
      return s.busy ? s : { ...initialCardState, download: s.download }
    case "files_copied":
      return s.dialog?.kind === "delete" && !s.busy ? { ...s, dialog: { ...s.dialog, filesCopied: e.value } } : s
    case "sent":
      return { ...s, busy: true, error: null }
    case "done":
      return e.error ? { ...s, busy: false, error: e.error } : { ...initialCardState, download: s.download }
    case "download":
      return s.busy || s.download?.phase === "busy" ? s : { ...s, download: { vm: e.vm, phase: "busy", error: null, skipped: 0 } }
    case "download_done":
      // The files-copied checkbox is never ticked here: only the person knows the archive opened.
      return s.download?.vm === e.vm ? { ...s, download: { vm: e.vm, phase: e.error ? "failed" : "started", error: e.error, skipped: e.skipped } } : s
  }
}

/** The export op for a paused retired VM of the list, else null (a pausing VM is not fenced yet). */
export const exportRequest = (view: TeamVmView, vm: string): { readonly op: "team_vm.retired.export"; readonly params: { readonly vm: string } } | null =>
  view.retired.find((r) => r.vm === vm)?.state === "paused" ? { op: "team_vm.retired.export", params: { vm } } : null

export interface TeamVmRequest {
  readonly op: "team_vm.taint.accept" | "team_vm.rebuild" | "team_vm.retired.delete"
  readonly params: Record<string, unknown>
}

/**
 * The op the open dialog would send, or null when it may not be sent yet: Accept names exactly the
 * tainted epoch and removed members that status showed; Rebuild names the current epoch; Delete
 * needs a paused retired VM of that id and the files-copied checkbox.
 */
export const teamVmRequest = (view: TeamVmView, dialog: Dialog | null): TeamVmRequest | null => {
  if (!dialog) return null
  switch (dialog.kind) {
    case "accept":
      return view.taint && !view.taint.accepted_by ? { op: "team_vm.taint.accept", params: { epoch: view.taint.epoch, users: [...view.taint.users] } } : null
    case "rebuild":
      return view.vm !== null ? { op: "team_vm.rebuild", params: { epoch: view.epoch } } : null
    case "delete": {
      const row = view.retired.find((r) => r.vm === dialog.vm)
      return row?.state === "paused" && dialog.filesCopied ? { op: "team_vm.retired.delete", params: { vm: row.vm, files_copied: true } } : null
    }
  }
}

export interface MemberRow {
  readonly user: string
  readonly role: string
}

/** One team.members.list page: members after `cursor` (a user id), and the cursor of the next page or null. */
export type MembersPage = (cursor: string) => Promise<{ readonly members: ReadonlyArray<MemberRow>; readonly next_cursor: string | null } | null>

/**
 * The caller's role. team.directory holds only the first `pageSize` members, so for a larger team
 * this pages team.members.list from the directory's last member until it finds the caller (at most
 * `maxPages` reads); null when the caller is not found.
 */
export const callerRole = async (me: string, directory: ReadonlyArray<MemberRow>, page: MembersPage, pageSize = 200, maxPages = 50): Promise<TeamRole | null> => {
  if (!me) return null
  const own = directory.find((m) => m.user === me)
  if (own) return roleOf(own.role)
  let cursor = directory.length >= pageSize ? directory.at(-1)?.user : undefined
  for (let i = 0; cursor && i < maxPages; i++) {
    const p = await page(cursor)
    if (!p) return null
    const found = p.members.find((m) => m.user === me)
    if (found) return roleOf(found.role)
    cursor = p.next_cursor ?? undefined
  }
  return null
}
