import type { ObjectState } from "./do-runtime/object-state.ts"

/** One person this server admitted. */
export interface RosterMember {
  readonly user: string
  readonly login: string
  readonly display_name: string
  readonly first_seen: number
}

/**
 * The people of one self-hosted server, in its own object. Everyone the server admits is one
 * team for the Home reach rule (home-reach.ts asks `homeCoMembers`), so admitted people can open
 * DMs and groups with each other. It answers the TeamDO calls the chat owners make; every team
 * id resolves to this one object on a server.
 */
export class RosterDO {
  constructor(private readonly ctx: ObjectState) {
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS members (user TEXT PRIMARY KEY, login TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL, first_seen INTEGER NOT NULL)")
  }

  /** Records an admitted person (display name refreshed); returns true the first time. */
  async join(user: string, login: string, displayName: string, now = Date.now()): Promise<boolean> {
    const before = this.ctx.storage.sql.exec("SELECT user FROM members WHERE user = ?", user).toArray().length
    this.ctx.storage.sql.exec("INSERT INTO members (user, login, display_name, first_seen) VALUES (?, ?, ?, ?) ON CONFLICT(user) DO UPDATE SET display_name = excluded.display_name", user, login, displayName, now)
    return before === 0
  }

  async members(): Promise<Array<RosterMember>> {
    return this.ctx.storage.sql.exec<RosterMember>("SELECT user, login, display_name, first_seen FROM members ORDER BY first_seen").toArray()
  }

  /** TeamDO.homeCoMembers: the targets that share this server with `adder`. */
  async homeCoMembers(_team: string, adder: string, targets: ReadonlyArray<string>): Promise<Array<{ user: string; display_name: string }>> {
    const rows = this.ctx.storage.sql.exec<{ user: string; display_name: string }>("SELECT user, display_name FROM members").toArray()
    if (!rows.some((r) => r.user === adder)) return []
    const byUser = new Map(rows.map((r) => [r.user, r.display_name]))
    return targets.filter((t) => byUser.has(t)).map((t) => ({ user: t, display_name: byUser.get(t)! }))
  }

  /** TeamDO.memberRole: every admitted person is a member. */
  async memberRole(_team: string, user: string): Promise<string | null> {
    return this.ctx.storage.sql.exec("SELECT user FROM members WHERE user = ?", user).toArray().length ? "member" : null
  }

  /** TeamDO.membership (user-teams.ts). */
  async membership(team: string, user: string): Promise<{ team: string; role: string | null }> {
    return { team, role: await this.memberRole(team, user) }
  }

  /** No servers are placed on a self-hosted chat server. */
  async serverPlacementActive(): Promise<boolean> {
    return false
  }

  /** No SSH certificates on a self-hosted chat server. */
  async revokeInstallCerts(): Promise<{ ok: boolean }> {
    return { ok: true }
  }
}
