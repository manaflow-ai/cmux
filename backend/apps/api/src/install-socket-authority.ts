import type { Env } from "./env.ts"
import type { Attachment } from "./owner-do.ts"
import { closeQuietly } from "./socket-gate.ts"

export type InstallSocketRef = { install: string; grant: string | undefined; agent?: string; authority?: string }
export type InstallSocketView = string | null | { unavailable: true }

/** Fresh reads of UserDO fence captured sockets; later admissions and newer notices own their own checks. */
export class InstallSocketAuthority {
  private readonly notices = new Map<string, symbol>()
  constructor(private readonly env: Env, private readonly sockets: () => ReadonlyArray<WebSocket>) {}

  async changed(user: string, install: string): Promise<void> {
    const key = `${user}\u0000${install}`, notice = Symbol()
    this.notices.set(key, notice)
    const sockets = this.sockets().filter((socket) => {
      const p = (socket.deserializeAttachment() as Attachment | null)?.principal
      return p?.kind === "install" && p.user === user && p.install === install
    })
    const groups = new Map<string, { ref: InstallSocketRef; sockets: WebSocket[] }>()
    for (const socket of sockets) {
      const p = (socket.deserializeAttachment() as Attachment).principal
      const id = JSON.stringify([p.grant, p.agent])
      const group = groups.get(id) ?? { ref: { install, grant: p.grant, ...(p.agent ? { agent: p.agent } : {}) }, sockets: [] }
      group.sockets.push(socket); groups.set(id, group)
    }
    const candidates = [...groups.values()], errors: unknown[] = []
    try {
      const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(user))
      for (let offset = 0; offset < candidates.length; offset += 128) {
        const batch = candidates.slice(offset, offset + 128)
        let views: ReadonlyArray<InstallSocketView>
        try {
          views = await stub.installSocketAuthorities(user, batch.map((candidate) => candidate.ref))
          if (views.length !== batch.length) throw new Error("incomplete install authority batch")
        } catch (error) { errors.push(error); views = batch.map(() => ({ unavailable: true })) }
        if (this.notices.get(key) !== notice) return
        batch.forEach((candidate, index) => {
          const view = views[index]
          const version = typeof view === "string" && /^[0-9a-f]{64}$/.test(view) ? view : null
          if (view !== null && version === null) errors.push(new Error("install authority unavailable"))
          for (const socket of candidate.sockets) {
            const p = (socket.deserializeAttachment() as Attachment).principal
            if (version === null || p.install_authority !== version) closeQuietly(socket, 4401, "install authority changed")
          }
        })
      }
      if (errors.length) throw new AggregateError(errors, "install authority unavailable")
    } finally { if (this.notices.get(key) === notice) this.notices.delete(key) }
  }
}
