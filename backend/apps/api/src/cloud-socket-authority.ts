import type { Attachment } from "./owner-do.ts"
import { roleHas } from "./domains/team-roles.ts"
import { closeQuietly } from "./socket-gate.ts"
import type { TeamCloudAuthority } from "./domains/team-authority.ts"

type Membership = TeamCloudAuthority

/** Live TeamDO reads fence admission and compare persisted socket authority, never notice time or role alone. */
export class CloudSocketAuthority {
  private readonly checks = new Map<string, { notice: symbol; pending: number }>()

  constructor(
    private readonly membership: (team: string, user: string) => Promise<Membership>,
    private readonly sockets: () => ReadonlyArray<WebSocket>,
    private readonly memberships?: (team: string, users: ReadonlyArray<string>) => Promise<ReadonlyArray<Membership>>
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
    await this.reconcile(team, user, this.sockets().filter((socket) =>
      (socket.deserializeAttachment() as Attachment | null)?.principal?.user === user))
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
    // Fence every admission before the first await, then read bounded batches instead of one RPC per subscriber.
    const candidates = [...groups].map(([user, sockets]) => ({ user, sockets, notice: this.begin(user, true) }))
    const errors: unknown[] = []
    try {
      for (let offset = 0; offset < candidates.length; offset += 128) {
        const batch = candidates.slice(offset, offset + 128), users = batch.map((candidate) => candidate.user)
        let views: ReadonlyArray<Membership>
        try {
          views = this.memberships ? await this.memberships(team, users) : await Promise.all(users.map((user) =>
            this.membership(team, user).catch(() => ({ unavailable: true as const }))))
          if (views.length !== batch.length) throw new Error("incomplete Cloud authority batch")
        } catch (error) {
          errors.push(error)
          for (const candidate of batch) {
            if (this.checks.get(candidate.user)?.notice === candidate.notice) this.closeStale(candidate.user, null, candidate.sockets)
          }
          continue
        }
        for (let i = 0; i < batch.length; i++) {
          const candidate = batch[i]!
          if (this.checks.get(candidate.user)?.notice !== candidate.notice) continue
          try { this.closeStale(candidate.user, this.version(views[i]!), candidate.sockets) }
          catch (error) { errors.push(error); this.closeStale(candidate.user, null, candidate.sockets) }
        }
      }
    } finally { for (const candidate of candidates) this.finish(candidate.user) }
    if (errors.length) throw new AggregateError(errors, "Cloud team authority unavailable")
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
    return this.version(await this.membership(team, user))
  }

  private version(member: Membership): string | null {
    if (member === null) return null
    if (!member || typeof member !== "object" || "unavailable" in member) throw new Error("team authority is unavailable")
    if (!roleHas(member.role, "team.resources")) return null
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
