import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { PAIRING_TTL_MS } from "./domains/pairing.ts"

export interface PairingRecord {
  readonly code: string
  readonly public_jwk: { kty: "EC"; crv: "P-256"; x: string; y: string }
  readonly thumbprint: string
  readonly wg_public_key: string
  readonly info: { name: string; platform: string; os_version: string; arch: string; cmux_version: string }
  readonly country: string | null
  readonly expires_at: number
}

export interface PairingResult {
  readonly host: string
  readonly team: string
  readonly user: string
  readonly install: string
}

type Row = {
  code: string
  public_jwk: string
  thumbprint: string
  wg_public_key: string
  info: string
  country: string | null
  collect_hash: string
  expires_at: number
  result: string | null
}

const equal = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

/**
 * PairingDO: one object per pending pairing code (plans/cmux-next/server.md
 * 6.2), named by the normalized code. It is the single writer of that code's
 * state: pending, then approved once (single use), then deleted by its one-shot
 * alarm at expiry. The waiting server holds a hibernating WebSocket and gets the
 * result pushed; it never polls. Only the begin caller can wait, because the
 * socket must present the collect secret whose hash begin stored.
 */
export class PairingDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS pairing (id INTEGER PRIMARY KEY CHECK (id = 1), code TEXT NOT NULL, public_jwk TEXT NOT NULL, thumbprint TEXT NOT NULL,
        wg_public_key TEXT NOT NULL, info TEXT NOT NULL, country TEXT, collect_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, result TEXT)`
    )
  }

  private row(now: number): Row | undefined {
    const r = this.ctx.storage.sql.exec<Row>(`SELECT * FROM pairing WHERE id = 1`).toArray()[0]
    return r && r.expires_at > now ? r : undefined
  }

  private record(r: Row): PairingRecord {
    return { code: r.code, public_jwk: JSON.parse(r.public_jwk), thumbprint: r.thumbprint, wg_public_key: r.wg_public_key, info: JSON.parse(r.info), country: r.country, expires_at: r.expires_at }
  }

  /** Creates the pending pairing. Refuses when this code is already in use (the Worker picks another code). */
  async begin(input: Omit<PairingRecord, "expires_at"> & { collect_hash: string; now: number }): Promise<{ ok: true; expires_at: number } | { ok: false; reason: "in_use" }> {
    if (this.row(input.now)) return { ok: false, reason: "in_use" }
    const expires = input.now + PAIRING_TTL_MS
    this.ctx.storage.sql.exec(`DELETE FROM pairing`)
    this.ctx.storage.sql.exec(
      `INSERT INTO pairing (id, code, public_jwk, thumbprint, wg_public_key, info, country, collect_hash, expires_at, result) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
      input.code,
      JSON.stringify(input.public_jwk),
      input.thumbprint,
      input.wg_public_key,
      JSON.stringify(input.info),
      input.country,
      input.collect_hash,
      expires
    )
    await this.ctx.storage.setAlarm(expires)
    return { ok: true, expires_at: expires }
  }

  /** The pending record for the approver's preview, or null when the code is unknown, expired or used. */
  async preview(code: string, now: number): Promise<PairingRecord | null> {
    const r = this.row(now)
    return r && r.code === code && r.result === null ? this.record(r) : null
  }

  /** The pending record for an approval in progress (also after the result is stored, so a retry can finish). */
  async pending(code: string, now: number): Promise<{ record: PairingRecord; result: PairingResult | null } | null> {
    const r = this.row(now)
    return r && r.code === code ? { record: this.record(r), result: r.result ? (JSON.parse(r.result) as PairingResult) : null } : null
  }

  /**
   * Stores the approval once and pushes it to the waiting server. A repeat with
   * the same result is a no-op; a different result is refused (single use).
   */
  async complete(code: string, thumbprint: string, result: PairingResult, now: number): Promise<{ ok: true } | { ok: false; message: string }> {
    const r = this.row(now)
    if (!r || r.code !== code) return { ok: false, message: "pairing code expired or unknown" }
    if (!equal(r.thumbprint, thumbprint)) return { ok: false, message: "pairing key changed" }
    const json = JSON.stringify(result)
    if (r.result !== null) return r.result === json ? { ok: true } : { ok: false, message: "pairing code already used" }
    this.ctx.storage.sql.exec(`UPDATE pairing SET result = ? WHERE id = 1`, json)
    for (const ws of this.ctx.getWebSockets()) {
      ws.send(JSON.stringify({ t: "paired", ...result }))
      ws.close(1000, "paired")
    }
    return { ok: true }
  }

  /** `GET /v1/pair/wait` (WebSocket). The Worker passes the SHA-256 of the presented collect secret. */
  override async fetch(request: Request): Promise<Response> {
    const r = this.row(Date.now())
    const presented = request.headers.get("x-cmux-collect-hash") ?? ""
    if (!r || !equal(r.collect_hash, presented)) return new Response("not found", { status: 404 })
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    this.ctx.acceptWebSocket(server)
    if (r.result !== null) {
      server.send(JSON.stringify({ t: "paired", ...(JSON.parse(r.result) as PairingResult) }))
      server.close(1000, "paired")
    } else {
      server.send(JSON.stringify({ t: "pending", expires_at: r.expires_at }))
    }
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": "cmux.pair.v1" } })
  }

  /** The server sends nothing; any message is ignored (no state change from the socket). */
  override async webSocketMessage(): Promise<void> {}

  /** One-shot expiry: forget the code and tell a waiting server. */
  override async alarm(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) ws.close(4408, "expired")
    this.ctx.storage.sql.exec(`DELETE FROM pairing`)
  }
}
