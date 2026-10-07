import type { Principal } from "@cmux/ownership"
import { cloudOpByName } from "@cmux/protocol"
import type { Env } from "./env.ts"
import type { Attachment } from "./owner-do.ts"

/** How long a socket's install status from UserDO is trusted before its events wait for a new check. */
export const INSTALL_CHECK_MS = 60_000
/** Frames one socket may have waiting behind a revocation check. */
const MAX_QUEUED_FRAMES = 256

export const closeQuietly = (ws: WebSocket, code: number, reason: string) => {
  try {
    ws.close(code, reason)
  } catch {}
}

type InstallRef = { install: string; grant: string | undefined; agent?: string }

/** The refusal for a frame whose install could not be checked; it names the frame's idempotency key. */
const unreachable = (ws: WebSocket, message: string | ArrayBuffer) => {
  let key: unknown
  try {
    key = (JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message)) as { idempotency_key?: unknown }).idempotency_key
  } catch {}
  try {
    ws.send(JSON.stringify({ t: "error", code: "owner.unreachable", message: "could not check this install; retry", ...(typeof key === "string" ? { idempotency_key: key } : {}) }))
  } catch {}
}

type ChiefGrant = { ok: true; op_classes: ReadonlyArray<string> } | { ok: false }

/**
 * A chief token holding mutate-shared (a paired server acting as its placed chief): its socket's chief rights are
 * confirmed per mutating frame. No install_kind condition: a path that leaves it out still gets the check (fail closed).
 */
const placedChiefToken = (p: Principal) => p.kind === "install" && !!p.agent && (p.grant_classes ?? []).includes("mutate-shared")

/** An op frame that writes (an unknown op counts as one: fail closed). */
const mutatingFrame = (message: string | ArrayBuffer): { key?: string } | null => {
  try {
    const f = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message)) as { t?: unknown; op?: unknown; idempotency_key?: unknown }
    if (f.t !== "op") return null
    const key = typeof f.idempotency_key === "string" ? f.idempotency_key : undefined
    return cloudOpByName.get(String(f.op))?.class === "read" ? null : { ...(key ? { key } : {}) }
  } catch {
    return null
  }
}

/**
 * Token expiry and install revocation for the sockets of one owner object (P0, coordinator
 * 2026-10-03). An expired token closes a socket (4401 "token expired"). An install's status is
 * trusted INSTALL_CHECK_MS (seeded at connect, where the Worker checked it); after that its events
 * wait while UserDO.installsActive is asked (batched per user, in parallel); a revoked install
 * closes (4401 "install revoked"), an active one gets a snapshot. An unreachable UserDO keeps the
 * socket held (fail closed). Memory only: hibernation clears it, and the next frame asks again.
 */
export class SocketGate {
  private readonly checks = new Map<string, { active: boolean; at: number }>()
  private readonly held = new Set<WebSocket>()
  private checking = false

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env,
    private readonly enabled: () => boolean,
    private readonly resync: (ws: WebSocket, a: Attachment) => void
  ) {}

  private key = (p: Principal) => `${p.user}\u0000${p.install}\u0000${p.grant ?? ""}\u0000${p.agent ?? ""}`
  private watched = (p: Principal) => this.enabled() && p.kind === "install" && !!p.install && !!p.user

  /**
   * The Worker checked this install when it opened the socket. The socket is also registered in
   * the user's UserDO, so a revoke closes it at once (socket-registry.ts); a refused registration
   * (revoked in between) closes it now.
   */
  seed(ws: WebSocket, p: Principal, owner: { cls: string; name: string }): void {
    if (!this.watched(p)) return
    this.checks.set(this.key(p), { active: true, at: Date.now() })
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(p.user!)) as unknown as {
      registerSocket(entity: string, install: string, grant: string | undefined, cls: string, name: string, expiresAt: number, agent?: string): Promise<boolean>
    }
    const expires = p.expires_at ?? Date.now() + 3600_000
    this.ctx.waitUntil(
      stub.registerSocket(p.user!, p.install!, p.grant, owner.cls, owner.name, expires, p.agent).then(
        (ok) => {
          if (ok) return
          this.revoked(p.install!)
          closeQuietly(ws, 4401, "install revoked")
        },
        // UserDO unreachable: the socket stays, and the 60 s check closes it if the install is revoked.
        () => undefined
      )
    )
  }

  /** The install was revoked (UserDO push): every cached status of it becomes inactive. */
  revoked(install: string): void {
    for (const k of [...this.checks.keys()]) if (k.split("\u0000")[1] === install) this.checks.set(k, { active: false, at: Date.now() })
  }

  closed(ws: WebSocket): void {
    this.held.delete(ws)
    this.chains.delete(ws)
    this.depth.delete(ws)
  }

  private readonly chains = new Map<WebSocket, Promise<void>>()
  private readonly depth = new Map<WebSocket, number>()

  /**
   * Runs `route` for one frame after every earlier frame of the same socket, and only when the
   * frame passes the gate (frameAllowed) and the socket is still open. A client that floods frames
   * while a check is pending is closed (1008) instead of queued without bound.
   */
  async enqueue(ws: WebSocket, message: string | ArrayBuffer, route: () => Promise<void> | void, stream?: string): Promise<void> {
    const depth = (this.depth.get(ws) ?? 0) + 1
    if (depth > MAX_QUEUED_FRAMES) return closeQuietly(ws, 1008, "too many frames")
    this.depth.set(ws, depth)
    const next = (this.chains.get(ws) ?? Promise.resolve())
      .then(async () => {
        const a = ws.deserializeAttachment() as Attachment
        let gate = await this.frameAllowed(ws, a)
        if (gate === true) gate = await this.chiefFrameAllowed(ws, a, message)
        if (gate === "unreachable") return unreachable(ws, message)
        if (gate !== true || ws.readyState !== WebSocket.READY_STATE_OPEN) return
        await route()
      })
      .catch((e: unknown) => console.error(JSON.stringify({ msg: "socket frame failed", stream, error: String(e) })))
      .finally(() => this.depth.set(ws, (this.depth.get(ws) ?? 1) - 1))
    this.chains.set(ws, next)
    await next
    if (this.chains.get(ws) === next) this.chains.delete(ws)
  }

  forget(): void {
    this.checks.clear()
  }

  /** Whether a socket may receive a frame now. */
  live(ws: WebSocket, a: Attachment, now = Date.now()): boolean {
    const p = a.principal
    if (p.expires_at !== undefined && p.expires_at <= now) {
      closeQuietly(ws, 4401, "token expired")
      return false
    }
    if (this.watched(p)) {
      const c = this.checks.get(this.key(p))
      if (c && !c.active) {
        closeQuietly(ws, 4401, "install revoked")
        return false
      }
      if (!c || now - c.at > INSTALL_CHECK_MS) {
        this.held.add(ws)
        this.ctx.waitUntil(this.run())
        return false
      }
    }
    return !this.held.has(ws)
  }

  /**
   * Gate for frames a socket sends: an expired token or a revoked install closes the socket; a
   * stale status is checked now (one UserDO RPC) before the frame is routed. An unreachable
   * UserDO refuses the frame (fail closed) and keeps the socket.
   */
  async frameAllowed(ws: WebSocket, a: Attachment): Promise<true | false | "unreachable"> {
    const p = a.principal
    if (p.expires_at !== undefined && p.expires_at <= Date.now()) {
      closeQuietly(ws, 4401, "token expired")
      return false
    }
    if (!this.watched(p)) return true
    const key = this.key(p)
    let c = this.checks.get(key)
    if (!c || Date.now() - c.at > INSTALL_CHECK_MS) {
      const status = await this.ask(p.user!, [{ install: p.install!, grant: p.grant, ...(p.agent ? { agent: p.agent } : {}) }])
      if (!status) return "unreachable"
      c = { active: status[0] === true, at: Date.now() }
      this.checks.set(key, c)
      // A socket held by a failed background check is released now that the status is fresh.
      if (this.held.size > 0) this.ctx.waitUntil(this.run())
    }
    if (!c.active) {
      closeQuietly(ws, 4401, "install revoked")
      return false
    }
    return true
  }

  /**
   * A placed Chief's socket (G8): its chief rights were resolved at connect, so every mutating frame asks
   * UserDO.installGrant again, which asks TeamDO (the server's authority); nothing is cached. A server
   * revoked in TeamDO (also before UserDO hears of it), a chief moved off the server or archived refuses
   * the frame and closes the socket (4401); an unreachable UserDO or TeamDO refuses the frame (fail closed).
   */
  async chiefFrameAllowed(ws: WebSocket, a: Attachment, message: string | ArrayBuffer): Promise<true | false | "unreachable"> {
    const p = a.principal
    if (!placedChiefToken(p) || !p.user || !p.install) return true
    const frame = mutatingFrame(message)
    if (!frame) return true
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(p.user)) as unknown as {
      installGrant(entity: string, install: string, grant: string | undefined, agent?: string): Promise<ChiefGrant>
    }
    const r = await stub.installGrant(p.user, p.install, p.grant, p.agent).catch(() => null)
    if (r === null) return "unreachable"
    if (r.ok && r.op_classes.includes("mutate-shared")) return true
    try {
      ws.send(JSON.stringify({ t: "error", code: "auth.forbidden", message: "the chief no longer runs on this server", ...(frame.key ? { idempotency_key: frame.key } : {}) }))
    } catch {}
    closeQuietly(ws, 4401, "chief rights changed")
    return false
  }

  /** Closes sockets whose token expired (alarm sweep: also with no events). */
  sweep(now: number): void {
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() as Attachment | null
      if (a?.principal.expires_at !== undefined && a.principal.expires_at <= now) closeQuietly(ws, 4401, "token expired")
    }
  }

  /** The earliest future token expiry of an open socket, or null (a past one was already swept). */
  nextExpiry(): number | null {
    let at: number | null = null
    for (const ws of this.ctx.getWebSockets()) {
      const e = (ws.deserializeAttachment() as Attachment | null)?.principal.expires_at
      if (typeof e === "number" && e > Date.now() && (at === null || e < at)) at = e
    }
    return at
  }

  private ask(user: string, list: ReadonlyArray<InstallRef>): Promise<ReadonlyArray<boolean> | null> {
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(user)) as unknown as { installsActive(entity: string, list: ReadonlyArray<InstallRef>): Promise<ReadonlyArray<boolean>> }
    return stub.installsActive(user, list).catch(() => null)
  }

  /** Asks UserDO about every held socket's install, then closes revoked ones and resyncs the rest. */
  private async run(): Promise<void> {
    if (this.checking) return
    this.checking = true
    try {
      while (this.held.size > 0) {
        const held = [...this.held]
        const byUser = new Map<string, Map<string, InstallRef>>()
        for (const ws of held) {
          const p = (ws.deserializeAttachment() as Attachment | null)?.principal
          if (!p?.user || !p.install) continue
          const m = byUser.get(p.user) ?? new Map<string, InstallRef>()
          m.set(this.key(p), { install: p.install, grant: p.grant, ...(p.agent ? { agent: p.agent } : {}) })
          byUser.set(p.user, m)
        }
        const now = Date.now()
        const results = await Promise.all([...byUser].map(async ([user, installs]) => ({ installs, status: await this.ask(user, [...installs.values()]) })))
        // Unreachable UserDO: fail closed (the sockets stay held; the next frame asks again).
        if (results.some((r) => r.status === null)) return
        for (const { installs, status } of results) [...installs.keys()].forEach((k, i) => this.checks.set(k, { active: status![i] === true, at: now }))
        for (const ws of held) {
          this.held.delete(ws)
          const a = ws.deserializeAttachment() as Attachment | null
          if (a && this.live(ws, a)) this.resync(ws, a)
        }
      }
    } finally {
      this.checking = false
    }
  }
}
