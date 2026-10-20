import type { Attachment } from "./owner-do.ts"
import { roleHas } from "./domains/team-roles.ts"
import { closeQuietly } from "./socket-gate.ts"

type Membership = { role: string; authority_version: string } | null

/** Live TeamDO reads fence admission and compare persisted socket authority, never notice time or role alone. */
export class CloudSocketAuthority {
  private readonly checks = new Map<string, { notice: symbol; pending: number }>()

  constructor(
    private readonly membership: (team: string, user: string) => Promise<Membership>,
    private readonly sockets: () => ReadonlyArray<WebSocket>
  ) {}

  async admit(team: string, user: string): Promise<string | null> {
    const notice = this.begin(user, false)
    try {
      const version = await this.current(team, user).catch(() => null)
      return this.checks.get(user)?.notice === notice ? version : null
    } finally { this.finish(user) }
  }

  async changed(team: string, user: string): Promise<void> {
    const notice = this.begin(user, true)
    try {
      let version: string | null
      try { version = await this.current(team, user) }
      catch (error) {
        if (this.checks.get(user)?.notice === notice) this.closeStale(user, null)
        throw error // No acknowledgement: the durable outbox retries an unavailable owner.
      }
      // A newer notice owns the check if its RPC overtook this one.
      if (this.checks.get(user)?.notice === notice) this.closeStale(user, version)
    } finally { this.finish(user) }
  }

  private begin(user: string, changed: boolean): symbol {
    const check = this.checks.get(user) ?? { notice: Symbol(), pending: 0 }
    if (changed) check.notice = Symbol()
    check.pending++
    this.checks.set(user, check)
    return check.notice
  }

  private finish(user: string): void {
    const check = this.checks.get(user)!
    if (--check.pending === 0) this.checks.delete(user)
  }

  private async current(team: string, user: string): Promise<string | null> {
    const member = await this.membership(team, user)
    if (!member || !roleHas(member.role, "team.resources")) return null
    if (!/^[0-9a-f]{64}$/.test(member.authority_version)) throw new Error("team authority is unavailable")
    return member.authority_version
  }

  private closeStale(user: string, version: string | null): void {
    for (const socket of this.sockets()) {
      const attachment = socket.deserializeAttachment() as Attachment | null
      if (attachment?.principal.user === user && (version === null || attachment.team_authority !== version)) {
        closeQuietly(socket, 4401, "team authority changed")
      }
    }
  }
}
