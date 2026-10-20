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

  /** Register synchronously inside the ticket, without an untracked gap after the checked owner read. */
  async admit(team: string, user: string, accept: (version: string) => Response): Promise<Response | null> {
    const notice = this.begin(user, false)
    try {
      const version = await this.current(team, user).catch(() => null)
      return version !== null && this.checks.get(user)?.notice === notice ? accept(version) : null
    } finally { this.finish(user) }
  }

  async changed(team: string, user: string): Promise<void> {
    await this.reconcile(team, user, [...this.sockets()])
  }

  /** Include existing subscribers and admissions whose owner reads are still pending. */
  async changedAll(team: string): Promise<void> {
    const groups = new Map<string, Array<WebSocket>>([...this.checks.keys()].map((user) => [user, []]))
    for (const socket of this.sockets()) {
      const user = (socket.deserializeAttachment() as Attachment | null)?.principal?.user
      if (typeof user !== "string") continue
      const sockets = groups.get(user) ?? []
      sockets.push(socket); groups.set(user, sockets)
    }
    const results = await Promise.allSettled([...groups].map(([user, sockets]) => this.reconcile(team, user, sockets)))
    const failed = results.filter((result): result is PromiseRejectedResult => result.status === "rejected")
    if (failed.length) throw new AggregateError(failed.map((result) => result.reason), "Cloud team authority unavailable")
  }

  private async reconcile(team: string, user: string, sockets: ReadonlyArray<WebSocket>): Promise<void> {
    const notice = this.begin(user, true)
    // Only candidates captured before this RPC can close; newer independently admitted sockets are preserved.
    try {
      let version: string | null
      try { version = await this.current(team, user) }
      catch (error) {
        if (this.checks.get(user)?.notice === notice) this.closeStale(user, null, sockets)
        throw error // No acknowledgement: the durable outbox retries an unavailable owner.
      }
      // A newer notice owns the check if its RPC overtook this one.
      if (this.checks.get(user)?.notice === notice) this.closeStale(user, version, sockets)
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

  private closeStale(user: string, version: string | null, sockets: ReadonlyArray<WebSocket>): void {
    for (const socket of sockets) {
      const attachment = socket.deserializeAttachment() as Attachment | null
      if (attachment?.principal.user === user && (version === null || attachment.team_authority !== version)) {
        closeQuietly(socket, 4401, "team authority changed")
      }
    }
  }
}
