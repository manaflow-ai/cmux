import { PAIRING_TTL_MS } from "./domains/pairing.ts"

/**
 * Invite state for the reverse pairing flow (a signed-in device shows the code, the new machine
 * types it: `cmux pair CODE`). It lives in PairingDO instances under two more names, so the
 * deployment adds no Durable Object class:
 *
 * - `invite:<code>`: the single writer of one invite. Open until its first redemption, then
 *   `arrived` (bound to the box's key thumbprint and its 8-symbol pairing code), then `paired`
 *   or `voided`. One-shot alarm at the end of its life; the inviter's watcher socket hears every
 *   change pushed, never polled.
 * - `invite-user:<user>`: the person's invites: idempotency keys and the one live invite
 *   (pair-invite-owner.ts).
 *
 * The functions take the object's storage and sockets; PairingDO's methods call them.
 */

export type InviteState = "open" | "arrived" | "paired" | "voided"

/** `revoked`: the server this invite paired was revoked (server.revoke, or the box signed itself out). */
export type InviteVoidReason = "second_redemption" | "replaced" | "revoked"

export interface InviteArrival {
  readonly code: string
  readonly thumbprint: string
  readonly info: unknown
  readonly country: string | null
  /** The pairing code's expiry. */
  readonly expires_at: number
}

type InviteRow = {
  invite: string
  approver: string
  team: string
  inviter: string | null
  watch_hash: string
  expires_at: number
  live_until: number
  state: InviteState
  code: string | null
  thumbprint: string | null
  arrival: string | null
  host: string | null
  void_reason: string | null
}

export type InvitePeek =
  | { readonly state: "unknown" }
  | { readonly state: "used" }
  | { readonly state: "open"; readonly approver: string; readonly team: string; readonly inviter: string | null }
  | { readonly state: "arrived"; readonly approver: string; readonly team: string; readonly inviter: string | null; readonly code: string; readonly thumbprint: string }

export type InviteRedeem =
  | { readonly ok: true; readonly code: string }
  | { readonly ok: false; readonly reason: "unknown" | "used" }
  | { readonly ok: false; readonly reason: "voided"; readonly first: string | null }

const equal = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

/** The close code a voided invite's watcher gets. */
export const INVITE_VOIDED_CLOSE = 4409

export const inviteSchema = (sql: SqlStorage): void => {
  sql.exec(
    `CREATE TABLE IF NOT EXISTS pair_invite (id INTEGER PRIMARY KEY CHECK (id = 1), invite TEXT NOT NULL, approver TEXT NOT NULL, team TEXT NOT NULL, inviter TEXT,
      watch_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, live_until INTEGER NOT NULL, state TEXT NOT NULL, code TEXT, thumbprint TEXT, arrival TEXT, host TEXT, void_reason TEXT)`
  )
}

export class InviteStore {
  constructor(private readonly ctx: DurableObjectState) {}

  private get sql() {
    return this.ctx.storage.sql
  }

  private row(now: number): InviteRow | undefined {
    const r = this.sql.exec<InviteRow>(`SELECT * FROM pair_invite WHERE id = 1`).toArray()[0]
    return r && r.live_until > now ? r : undefined
  }

  private watchers(): Array<WebSocket> {
    return this.ctx.getWebSockets("invite")
  }

  private push(frame: unknown, close?: { code: number; reason: string }): void {
    const text = JSON.stringify(frame)
    for (const ws of this.watchers()) {
      ws.send(text)
      if (close) ws.close(close.code, close.reason)
    }
  }

  private arrivedFrame(r: InviteRow): Record<string, unknown> | null {
    return r.arrival ? { t: "arrived", ...(JSON.parse(r.arrival) as Record<string, unknown>) } : null
  }

  /**
   * A fresh invite. A repeat by the same person with the same watch secret (a replayed request
   * key) answers the minted one; any other use of a live code is refused (the Worker picks another).
   */
  async mint(input: { invite: string; approver: string; team: string; inviter: string | null; watch_hash: string; now: number }): Promise<{ ok: true; expires_at: number } | { ok: false; reason: "in_use" }> {
    const live = this.row(input.now)
    if (live) return live.invite === input.invite && live.approver === input.approver && equal(live.watch_hash, input.watch_hash) ? { ok: true, expires_at: live.expires_at } : { ok: false, reason: "in_use" }
    const expires = input.now + PAIRING_TTL_MS
    this.sql.exec(`DELETE FROM pair_invite`)
    this.sql.exec(
      `INSERT INTO pair_invite (id, invite, approver, team, inviter, watch_hash, expires_at, live_until, state) VALUES (1, ?, ?, ?, ?, ?, ?, ?, 'open')`,
      input.invite,
      input.approver,
      input.team,
      input.inviter,
      input.watch_hash,
      expires,
      expires
    )
    await this.ctx.storage.setAlarm(expires)
    return { ok: true, expires_at: expires }
  }

  /** Whether this invite was minted (in any state, until its object forgets it), for the owner's alarm. */
  async minted(invite: string, now: number): Promise<{ expires_at: number } | null> {
    const r = this.row(now)
    return r && r.invite === invite ? { expires_at: r.expires_at } : null
  }

  /** Read only: what a begin with this invite would meet. An open invite past its expiry is unknown. */
  async peek(invite: string, now: number): Promise<InvitePeek> {
    const r = this.row(now)
    if (!r || r.invite !== invite) return { state: "unknown" }
    if (r.state === "voided" || r.state === "paired") return { state: "used" }
    if (r.state === "open") return now < r.expires_at ? { state: "open", approver: r.approver, team: r.team, inviter: r.inviter } : { state: "unknown" }
    return { state: "arrived", approver: r.approver, team: r.team, inviter: r.inviter, code: r.code!, thumbprint: r.thumbprint! }
  }

  /**
   * The atomic redemption. The first binds the box's thumbprint and pairing code and tells the
   * inviter; the same thumbprint again gets the bound code back (a retry); any other thumbprint
   * voids the invite and returns the first box's code so its pairing is aborted.
   */
  async redeem(invite: string, arrival: InviteArrival, now: number): Promise<InviteRedeem> {
    const r = this.row(now)
    if (!r || r.invite !== invite) return { ok: false, reason: "unknown" }
    if (r.state === "voided" || r.state === "paired") return { ok: false, reason: "used" }
    if (r.state === "arrived") {
      if (equal(r.thumbprint!, arrival.thumbprint)) return { ok: true, code: r.code! }
      return { ok: false, reason: "voided", first: this.voidRow(r, "second_redemption") }
    }
    if (now >= r.expires_at) return { ok: false, reason: "unknown" }
    // The pairing code may outlive the invite's redemption window; the watcher stays until it ends.
    const liveUntil = Math.max(r.live_until, arrival.expires_at)
    const saved = JSON.stringify({ code: arrival.code, info: arrival.info, thumbprint: arrival.thumbprint, country: arrival.country, expires_at: arrival.expires_at })
    this.sql.exec(`UPDATE pair_invite SET state = 'arrived', code = ?, thumbprint = ?, arrival = ?, live_until = ? WHERE id = 1`, arrival.code, arrival.thumbprint, saved, liveUntil)
    await this.ctx.storage.setAlarm(liveUntil)
    this.push({ t: "arrived", ...(JSON.parse(saved) as Record<string, unknown>) })
    return { ok: true, code: arrival.code }
  }

  private voidRow(r: InviteRow, reason: InviteVoidReason): string | null {
    this.sql.exec(`UPDATE pair_invite SET state = 'voided', void_reason = ? WHERE id = 1`, reason)
    this.push({ t: "voided", reason }, { code: INVITE_VOIDED_CLOSE, reason: "voided" })
    return r.code
  }

  /**
   * Void a live invite that is not paired yet (a newer invite replaced it). Returns the bound pairing
   * code, if any; for an invite already voided it returns that code again (without a second push), so
   * a caller whose abort of that code failed can retry it. A `revoked` void also ends a paired
   * invite: the server it paired is gone, so a reconnecting watcher hears `voided {reason:"revoked"}`.
   */
  async void(invite: string, reason: InviteVoidReason, now: number): Promise<{ ok: boolean; code: string | null }> {
    const r = this.row(now)
    if (!r || r.invite !== invite || (r.state === "paired" && reason !== "revoked")) return { ok: false, code: null }
    if (r.state === "voided") return { ok: true, code: r.code }
    return { ok: true, code: this.voidRow(r, reason) }
  }

  /** The server this object's invite paired was revoked: void it `revoked`, whatever its state. Idempotent. */
  async revoked(now: number): Promise<{ ok: boolean }> {
    const r = this.row(now)
    if (!r) return { ok: false }
    if (r.state !== "voided") this.voidRow(r, "revoked")
    return { ok: true }
  }

  /** The inviter approved the box bound to this invite: tell the watcher. Idempotent. */
  async paired(invite: string, code: string, host: string, now: number): Promise<{ ok: boolean }> {
    const r = this.row(now)
    if (!r || r.invite !== invite || r.code !== code) return { ok: false }
    if (r.state === "paired") return { ok: r.host === host }
    if (r.state !== "arrived") return { ok: false }
    this.sql.exec(`UPDATE pair_invite SET state = 'paired', host = ? WHERE id = 1`, host)
    this.push({ t: "paired", host }, { code: 1000, reason: "paired" })
    return { ok: true }
  }

  /** `GET /v1/pair/invite/wait`: the Worker passes the SHA-256 of the presented watch secret. */
  watch(request: Request): Response {
    const r = this.row(Date.now())
    const presented = request.headers.get("x-cmux-watch-hash") ?? ""
    if (!r || !equal(r.watch_hash, presented)) return new Response("not found", { status: 404 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server, ["invite"])
    if (r.state === "voided") {
      server.send(JSON.stringify({ t: "voided", reason: r.void_reason }))
      server.close(INVITE_VOIDED_CLOSE, "voided")
    } else {
      server.send(JSON.stringify({ t: "pending", expires_at: r.expires_at }))
      const arrived = this.arrivedFrame(r)
      if (arrived) server.send(JSON.stringify(arrived))
      if (r.state === "paired") {
        server.send(JSON.stringify({ t: "paired", host: r.host }))
        server.close(1000, "paired")
      }
    }
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.pair-invite.v1" } })
  }

  /** The object's one-shot alarm: forget the invite. */
  expire(): void {
    this.sql.exec(`DELETE FROM pair_invite`)
  }
}
