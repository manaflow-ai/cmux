import type { Domain, Principal } from "@cmux/ownership"
import { address } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { sendInvite } from "./home-send.ts"

/** An attempt with no recorded outcome after this long is closed as indeterminate. */
const STALE_ATTEMPT_MS = 10 * 60_000
import type { Fetch } from "./home-send.ts"

/**
 * AddressDO, one per invited address (home-messaging.md sections 3 and 9, renamed from
 * ContactDO): the only copy of the raw address, suppression, per-recipient limits and the
 * delivery record, run by lane 15's pure domain.
 *
 * Stage C: a delivery committed as sending is sent once from the alarm (home-send.ts), behind the
 * fail-closed HOME_INVITES_SEND=on switch and the allow list; text waits for the vCard adapter.
 */
export class AddressDO extends OwnerDO<address.AddressHead> {
  constructor(ctx: DurableObjectState, env: Env) {
    // No client subscribes: subscribers would see the raw address.
    super(ctx, env, address.addressDomain as Domain<address.AddressHead>, "address")
  }

  /** Provider HTTP (tests replace it). */
  fetcher: Fetch = (url, init) => fetch(url, init as RequestInit)

  /**
   * RPC from the Worker before invite.create commits: the invite secret, kept only here (the
   * object that sends it) and deleted after the send or 24 h, whichever comes first.
   */
  /**
   * RPC from the Worker before invite.create commits: makes this object hold its raw address
   * (address.ensure, the only copy) and stashes the invite secret, which only this object sends.
   * The secret goes after the send attempt or after 24 h, whichever comes first.
   */
  async stashSecret(address: string, invite: string, secret: string, expiresAt: number, channel?: "email" | "sms", value?: string): Promise<void> {
    this.bind(address)
    if (channel && value) this.submitSystem("address.ensure", { id: address, channel, value }, `ensure:${address}`)
    this.tables()
    this.sqlStore.exec(`INSERT INTO address_secrets (invite, secret, expires_at) VALUES (?, ?, ?) ON CONFLICT (invite) DO NOTHING`, invite, secret, expiresAt)
    this.scheduleAlarm()
  }

  /** The stashed secret of an invite, if still there. */
  protected stashedSecret(invite: string): string | undefined {
    this.tables()
    return this.sqlStore.exec<{ secret: string }>(`SELECT secret FROM address_secrets WHERE invite = ? AND expires_at > ?`, invite, Date.now())[0]?.secret
  }

  private tables() {
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_secrets (invite TEXT PRIMARY KEY, secret TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    // One send attempt per delivery, ever (a provider call is not repeated, even after a restart).
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_attempts (invite TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
  }

  /** Deliveries the domain committed as sending that have no attempt yet. */
  private unsent(head: address.AddressHead): ReadonlyArray<address.DeliveryRecord> {
    this.tables()
    const tried = new Set(this.sqlStore.exec<{ invite: string }>(`SELECT invite FROM address_attempts`).map((r) => r.invite))
    return head.deliveries.filter((d) => d.state === "sending" && !tried.has(d.invite))
  }

  protected nextWakeAt(head: address.AddressHead, now: number): number | null {
    if (this.unsent(head).length > 0) return now
    const pending = this.sqlStore.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM address_attempts WHERE invite IN (SELECT value FROM json_each(?))`, JSON.stringify(head.deliveries.filter((d) => d.state === "sending").map((d) => d.invite)))[0]?.at
    if (pending !== null && pending !== undefined) return Number(pending) + STALE_ATTEMPT_MS
    const next = this.sqlStore.exec<{ at: number | null }>(`SELECT MIN(expires_at) AS at FROM address_secrets`)[0]?.at
    return next === null || next === undefined ? null : Number(next)
  }

  protected async onWake(now: number): Promise<void> {
    this.tables()
    const head = this.boundEngine?.currentState
    if (head?.channel && head.value) {
      for (const d of this.unsent(head)) {
        // Recorded before the call: a crash after this line never sends twice.
        this.sqlStore.exec(`INSERT INTO address_attempts (invite, at) VALUES (?, ?) ON CONFLICT (invite) DO NOTHING`, d.invite, now)
        let outcome: { state: address.DeliveryState; provider_id: string | null }
        try {
          outcome = await sendInvite(this.env, { invite: d.invite, conversation: d.conversation, channel: head.channel, value: head.value, secret: this.stashedSecret(d.invite) }, this.fetcher)
        } catch {
          // A throw comes before the provider call (deliverInvite catches its own network errors): nothing was sent.
          console.log(JSON.stringify({ msg: "home invite send", at: new Date(now).toISOString(), invite: d.invite, channel: head.channel, state: "failed", reason: "adapter error" }))
          outcome = { state: "failed", provider_id: null }
        }
        this.sqlStore.exec(`DELETE FROM address_secrets WHERE invite = ?`, d.invite)
        this.submitSystem("address.delivery.record", { invite: d.invite, state: outcome.state, ...(outcome.provider_id ? { provider_id: outcome.provider_id } : {}) }, `record:${d.invite}:${outcome.state}`)
      }
    }
    // An attempt that never recorded its outcome (the object stopped between the attempt row and the
    // record) may or may not have reached the provider: it is closed as indeterminate, never resent.
    if (head) {
      const stale = this.sqlStore.exec<{ invite: string }>(`SELECT invite FROM address_attempts WHERE at <= ?`, now - STALE_ATTEMPT_MS).map((r) => r.invite)
      for (const d of head.deliveries.filter((x) => x.state === "sending" && stale.includes(x.invite))) {
        this.sqlStore.exec(`DELETE FROM address_secrets WHERE invite = ?`, d.invite)
        this.submitSystem("address.delivery.record", { invite: d.invite, state: "indeterminate" }, `record:${d.invite}:indeterminate`)
      }
    }
    this.sqlStore.exec(`DELETE FROM address_secrets WHERE expires_at <= ?`, now)
  }

  protected maySubscribe(): boolean {
    return false
  }

  protected read(_head: address.AddressHead, op: string, _params: unknown, _principal: Principal): ReadResult {
    return { ok: false, code: "validation.invalid", message: `no client reads on addresses (${op})` }
  }
}
