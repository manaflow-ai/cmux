/**
 * Coalesces "this subscriber must resync" marks into one filtered snapshot per
 * socket per batch, building each user's view once (review P2: an MDM rollout
 * of N devices used to send N snapshots to every member). The owner supplies
 * the scheduler (a one-shot timer), the per-user view and the send.
 */
export class SnapshotBatcher<Socket> {
  private readonly pending = new Map<Socket, string>()
  private scheduled = false

  constructor(
    private readonly io: {
      readonly schedule: (flush: () => void) => void
      readonly viewFor: (user: string, socket: Socket) => string
      readonly send: (socket: Socket, text: string) => void
    }
  ) {}

  /** Marks `socket` (whose principal is `user`) for one snapshot in the next flush. */
  mark(socket: Socket, user: string) {
    this.pending.set(socket, user)
    if (this.scheduled) return
    this.scheduled = true
    this.io.schedule(() => this.flush())
  }

  /** Whether `socket` waits for a resync snapshot. */
  has(socket: Socket): boolean {
    return this.pending.has(socket)
  }

  /**
   * Sends `socket`'s pending snapshot now (before a visible event, so the
   * client sees no seq gap) and drops its mark.
   */
  flushOne(socket: Socket) {
    const user = this.pending.get(socket)
    if (user === undefined) return
    this.pending.delete(socket)
    this.io.send(socket, this.io.viewFor(user, socket))
  }

  flush() {
    this.scheduled = false
    const batch = [...this.pending]
    this.pending.clear()
    const views = new Map<string, string>()
    for (const [socket, user] of batch) {
      let text = views.get(user)
      if (text === undefined) {
        text = this.io.viewFor(user, socket)
        views.set(user, text)
      }
      this.io.send(socket, text)
    }
  }
}
