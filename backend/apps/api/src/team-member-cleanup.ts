import type { OwnerFrame } from "@cmux/ownership"
import type { TeamState } from "./domains/team.ts"
import { TABLE_HOST, type HostRecord, type RowsWithScan } from "./domains/team-members.ts"
import { KRL_GRACE_MS } from "./domains/team-ssh.ts"
import { ensureSshTables } from "./team-ssh-ca.ts"

export interface CleanupDeps {
  readonly state: () => TeamState
  readonly rows: RowsWithScan | undefined
  readonly sql: SqlStorage
  readonly now: () => number
  readonly submitSystem: (op: string, params: unknown, key: string) => { frames: ReadonlyArray<OwnerFrame> }
}

const HOST_PAGE = 200

const committed = (res: { frames: ReadonlyArray<OwnerFrame> }) => {
  const rej = res.frames.find((f) => f.t === "reject")
  if (rej && rej.t === "reject") throw new Error(`${rej.code}: ${rej.message}`)
}

/**
 * After team.member.remove (cx-44j.49), in the same turn and again from the alarm until done:
 * every live team SSH certificate the member got before the removal goes on the KRL at once (any
 * install, bound or not; issuance already refuses non-members), then their hosts are marked
 * orphaned for a team owner to reassign (never deleted) and the pending entry ends. Both steps are
 * idempotent (the KRL keeps a serial once; orphaned hosts are skipped), so a crash in between replays.
 */
export const cleanupRemovedMembers = (deps: CleanupDeps): number => {
  const pending = Object.entries(deps.state().member_cleanup ?? {})
  if (pending.length === 0) return 0
  ensureSshTables(deps.sql)
  for (const [user, at] of pending) {
    const now = deps.now()
    const serials = deps.sql
      .exec<{ serial: number; valid_before: number; generation: number }>(`SELECT serial, valid_before, generation FROM ssh_certs WHERE user = ? AND issued_at <= ? AND valid_before > ?`, user, at, now - KRL_GRACE_MS)
      .toArray()
      .map((r) => ({ serial: r.serial, valid_before: r.valid_before, generation: r.generation }))
    if (serials.length > 0) committed(deps.submitSystem("team_vm.ssh_certs_revoked", { serials, by: `system:member_removed:${user}`, admin: true, system: true, reason: "member removed" }, `member-certs:${user}:${at}`))
    const hosts: Array<string> = []
    let after: string | undefined
    for (;;) {
      const page = deps.rows?.scanFrom<HostRecord>(TABLE_HOST, after, HOST_PAGE) ?? []
      for (const r of page) if (r.row.owner_user === user && !r.row.orphaned && r.row.enrolled_at <= at) hosts.push(r.row.id)
      if (page.length < HOST_PAGE) break
      after = page[page.length - 1]!.key
    }
    // Legacy maps (an old head before team.rows_migrate) hold hosts too.
    for (const h of Object.values(deps.state().hosts ?? {})) if (h.owner_user === user && !h.orphaned && h.enrolled_at <= at && !hosts.includes(h.id)) hosts.push(h.id)
    committed(deps.submitSystem("team.member.cleaned", { user, hosts }, `member-cleaned:${user}:${at}`))
  }
  return pending.length
}
