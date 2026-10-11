/**
 * TeamDO's part of the team VM taint (cx-q4f3, domains/team-vm-taint.ts).
 *
 * `ssh_cert_holders` keeps, per member, the latest `valid_before` of any team SSH certificate this
 * team ever issued them. Unlike the issued log (`ssh_certs`, dropped 24 h after expiry) it is never
 * pruned (a re-join keeps it; the VM creation time makes an old entry harmless), so a removal still
 * knows that a member who last logged in weeks ago once held root on the current VM.
 */

export const ensureHolderTable = (sql: SqlStorage) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS ssh_cert_holders (user TEXT PRIMARY KEY, last_valid_before INTEGER NOT NULL)`)
}

/** Written with the issued-log row, before signing (a certificate that never got signed counts too). */
export const recordHolder = (sql: SqlStorage, user: string, validBefore: number) => {
  ensureHolderTable(sql)
  sql.exec(
    `INSERT INTO ssh_cert_holders (user, last_valid_before) VALUES (?, ?) ON CONFLICT(user) DO UPDATE SET last_valid_before = max(last_valid_before, excluded.last_valid_before)`,
    user,
    validBefore
  )
}

/**
 * The latest end of any certificate the member got: the holder record, or the issued log for
 * certificates from before the record existed. Null when they never had one.
 */
export const lastCertValidBefore = (sql: SqlStorage, user: string): number | null => {
  ensureHolderTable(sql)
  const held = sql.exec<{ v: number | null }>(`SELECT last_valid_before AS v FROM ssh_cert_holders WHERE user = ?`, user).toArray()[0]?.v ?? null
  const logged = sql.exec<{ v: number | null }>(`SELECT max(valid_before) AS v FROM ssh_certs WHERE user = ?`, user).toArray()[0]?.v ?? null
  if (held === null) return logged
  return logged === null ? held : Math.max(held, logged)
}

/** What TeamVmDO.taintStatus answers (team-vm-taint-run.ts TaintSummary). */
export interface VmTaint {
  readonly blocks: boolean
  readonly taint: { readonly epoch: number; readonly users: ReadonlyArray<string> } | null
}

/**
 * The certificate gate: while the team VM is tainted and not accepted, only owners and admins get a
 * certificate, and each one is audited with the taint. `refuse` for everyone else; `audit` names the
 * taint to record for an owner's or admin's certificate. An unreachable TeamVmDO fails closed.
 */
export const certTaintGate = async (vmTaint: (() => Promise<VmTaint | null>) | undefined, admin: boolean): Promise<{ refuse: boolean; unreachable: boolean; audit: { epoch: number; users: ReadonlyArray<string> } | null }> => {
  if (!vmTaint) return { refuse: false, unreachable: false, audit: null }
  let t: VmTaint | null
  try {
    t = await vmTaint()
  } catch {
    return { refuse: !admin, unreachable: true, audit: null }
  }
  if (!t?.blocks || !t.taint) return { refuse: false, unreachable: false, audit: null }
  return admin ? { refuse: false, unreachable: false, audit: { epoch: t.taint.epoch, users: t.taint.users } } : { refuse: true, unreachable: false, audit: null }
}
