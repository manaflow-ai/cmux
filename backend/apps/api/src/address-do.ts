import type { Domain, Principal } from "@cmux/ownership"
import { address } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { sendInvite } from "./home-send.ts"
import type { InviteSender } from "./home-routes.ts"

/** An attempt with no recorded outcome after this long is closed as indeterminate. */
const STALE_ATTEMPT_MS = 10 * 60_000
/** A contact card whose status never arrives within a day closes its invite as indeterminate. */
const CARD_WAIT_MS = 24 * 3_600_000
import type { Fetch } from "./home-send.ts"
import type { SendblueMessage } from "./home-text.ts"

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
  async stashSecret(address: string, invite: string, secret: string, expiresAt: number, channel?: "email" | "sms", value?: string, inviter?: InviteSender): Promise<void> {
    this.bind(address)
    if (channel && value) this.submitSystem("address.ensure", { id: address, channel, value }, `ensure:${address}`)
    this.tables()
    this.sqlStore.exec(`INSERT INTO address_secrets (invite, secret, expires_at) VALUES (?, ?, ?) ON CONFLICT (invite) DO NOTHING`, invite, secret, expiresAt)
    if (inviter) this.sqlStore.exec(`INSERT INTO address_inviters (invite, user, email, expires_at) VALUES (?, ?, ?, ?) ON CONFLICT (invite) DO NOTHING`, invite, inviter.user, inviter.email, expiresAt)
    this.scheduleAlarm()
  }

  /** The stashed secret of an invite, if still there. */
  protected stashedSecret(invite: string): string | undefined {
    this.tables()
    return this.sqlStore.exec<{ secret: string }>(`SELECT secret FROM address_secrets WHERE invite = ? AND expires_at > ?`, invite, Date.now())[0]?.secret
  }

  /** The invite's inviter (team inviter rule), if recorded and not expired. */
  protected inviterOf(invite: string): InviteSender | undefined {
    this.tables()
    const r = this.sqlStore.exec<{ user: string; email: string | null }>(`SELECT user, email FROM address_inviters WHERE invite = ? AND expires_at > ?`, invite, Date.now())[0]
    return r ? { user: r.user, email: r.email } : undefined
  }

  private tables() {
    // The inviter of each stashed invite, re-checked against HOME_INVITE_ALLOWED_INVITERS at send time.
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_inviters (invite TEXT PRIMARY KEY, user TEXT NOT NULL, email TEXT, expires_at INTEGER NOT NULL)`)
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_secrets (invite TEXT PRIMARY KEY, secret TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
    // One send attempt per delivery, ever (a provider call is not repeated, even after a restart).
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_attempts (invite TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
    // Text: invites waiting for their contact card's status, and whether this number ever got the card.
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_card_steps (invite TEXT PRIMARY KEY, card_handle TEXT NOT NULL, at INTEGER NOT NULL)`)
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_card_sent (at INTEGER NOT NULL)`)
  }

  /** Deliveries the domain committed as sending that have no attempt yet. */
  private unsent(head: address.AddressHead): ReadonlyArray<address.DeliveryRecord> {
    this.tables()
    const tried = new Set(this.sqlStore.exec<{ invite: string }>(`SELECT invite FROM address_attempts`).map((r) => r.invite))
    return head.deliveries.filter((d) => d.state === "sending" && !tried.has(d.invite))
  }

  protected nextWakeAt(head: address.AddressHead, now: number): number | null {
    if (this.unsent(head).length > 0) return now
    // An invite waiting on its card closes at the card deadline, any other open attempt at the stale deadline.
    const sending = JSON.stringify(head.deliveries.filter((d) => d.state === "sending").map((d) => d.invite))
    const pending = this.sqlStore.exec<{ at: number | null }>(
      `SELECT MIN(due) AS at FROM (
         SELECT a.at + ? AS due FROM address_attempts a WHERE a.invite IN (SELECT value FROM json_each(?)) AND a.invite NOT IN (SELECT invite FROM address_card_steps)
         UNION ALL SELECT c.at + ? AS due FROM address_card_steps c WHERE c.invite IN (SELECT value FROM json_each(?)))`,
      STALE_ATTEMPT_MS, sending, CARD_WAIT_MS, sending
    )[0]?.at
    if (pending !== null && pending !== undefined) return Math.max(Number(pending), now)
    const next = this.sqlStore.exec<{ at: number | null }>(`SELECT MIN(expires_at) AS at FROM address_secrets`)[0]?.at
    return next === null || next === undefined ? null : Number(next)
  }

  /** One step of an invite; a throw comes before any provider call, so it counts as failed (nothing sent). */
  private async step(head: address.AddressHead, d: address.DeliveryRecord, step: "email" | "text" | "card", firstText = false) {
    try {
      return await sendInvite(this.env, { invite: d.invite, conversation: d.conversation, channel: head.channel!, value: head.value!, secret: this.stashedSecret(d.invite), inviter: this.inviterOf(d.invite), suppression: head.suppression?.reason ?? null }, this.fetcher, step, firstText)
    } catch {
      console.log(JSON.stringify({ msg: "home invite send", at: new Date().toISOString(), invite: d.invite, channel: head.channel, step, state: "failed", reason: "adapter error" }))
      return { state: "failed" as const, provider_id: null }
    }
  }

  private record(invite: string, state: address.DeliveryState, providerId: string | null) {
    this.sqlStore.exec(`DELETE FROM address_secrets WHERE invite = ?`, invite)
    this.sqlStore.exec(`DELETE FROM address_inviters WHERE invite = ?`, invite)
    this.sqlStore.exec(`DELETE FROM address_card_steps WHERE invite = ?`, invite)
    this.submitSystem("address.delivery.record", { invite, state, ...(providerId ? { provider_id: providerId } : {}) }, `record:${invite}:${state}`)
  }

  protected async onWake(now: number): Promise<void> {
    this.tables()
    const head = this.boundEngine?.currentState
    if (head?.channel && head.value) {
      for (const d of this.unsent(head)) {
        // Recorded before the call: a crash after this line never sends twice.
        this.sqlStore.exec(`INSERT INTO address_attempts (invite, at) VALUES (?, ?) ON CONFLICT (invite) DO NOTHING`, d.invite, now)
        if (head.channel === "email") {
          const o = await this.step(this.boundEngine!.currentState, d, "email")
          this.record(d.invite, o.state, o.provider_id)
          continue
        }
        // Text: the contact card first to a number that never got one; the text after SendBlue reports it.
        const carded = this.sqlStore.exec(`SELECT 1 FROM address_card_sent LIMIT 1`).length > 0
        if (carded) {
          // The state again: a STOP that came in during an earlier send of this wake stops this text.
          const o = await this.step(this.boundEngine!.currentState, d, "text")
          this.record(d.invite, o.state, o.provider_id)
          continue
        }
        // One card per number: a card already on its way makes later invites wait for the same status.
        // Joiners take the card's own time, so every invite on a card that never reports closes together.
        const pending = this.sqlStore.exec<{ card_handle: string; at: number }>(`SELECT card_handle, MIN(at) AS at FROM address_card_steps GROUP BY card_handle ORDER BY at LIMIT 1`)[0]
        if (pending) {
          this.sqlStore.exec(`INSERT INTO address_card_steps (invite, card_handle, at) VALUES (?, ?, ?) ON CONFLICT (invite) DO NOTHING`, d.invite, pending.card_handle, pending.at)
          continue
        }
        const card = await this.step(head, d, "card")
        if (card.state === "sent" && card.provider_id) this.sqlStore.exec(`INSERT INTO address_card_steps (invite, card_handle, at) VALUES (?, ?, ?) ON CONFLICT (invite) DO NOTHING`, d.invite, card.provider_id, now)
        // A card accepted without a handle can never release its text: that invite failed.
        else this.record(d.invite, card.state === "sent" ? "failed" : card.state, card.provider_id)
      }
    }
    // An attempt that never recorded its outcome (the object stopped between the attempt row and the
    // record, or a card whose status never came within a day) may or may not have reached the
    // recipient: it is closed as indeterminate, never resent.
    if (head) {
      // The same deadlines as nextWakeAt: on a card, the card's time + CARD_WAIT_MS; otherwise the attempt + STALE_ATTEMPT_MS.
      const stale = new Set(
        this.sqlStore.exec<{ invite: string }>(
          `SELECT invite FROM address_card_steps WHERE at <= ?
           UNION SELECT invite FROM address_attempts WHERE at <= ? AND invite NOT IN (SELECT invite FROM address_card_steps)`,
          now - CARD_WAIT_MS, now - STALE_ATTEMPT_MS
        ).map((r) => r.invite)
      )
      for (const d of head.deliveries.filter((x) => x.state === "sending" && stale.has(x.invite))) this.record(d.invite, "indeterminate", null)
    }
    this.sqlStore.exec(`DELETE FROM address_secrets WHERE expires_at <= ?`, now)
    this.sqlStore.exec(`DELETE FROM address_inviters WHERE expires_at <= ?`, now)
  }

  /**
   * RPC from POST /v1/hooks/sendblue with SendBlue's own record of a message (home-text.ts).
   * A reported contact card releases the invite text; other statuses update the delivery; an
   * inbound STOP or an opt-out suppresses the number.
   */
  async textEvent(entity: string, m: SendblueMessage): Promise<void> {
    const engine = this.bind(entity)
    this.tables()
    const head = engine.currentState
    if (!head.value || head.channel !== "sms") return
    if (!m.is_outbound) {
      if (m.opted_out || address.keywordOf(m.content) === "stop") this.submitSystem("address.suppress", { reason: "opted_out" }, `suppress:${m.message_handle}`)
      return
    }
    if (m.opted_out) this.submitSystem("address.suppress", { reason: "opted_out" }, `suppress:${m.message_handle}`)
    const steps = this.sqlStore.exec<{ invite: string }>(`SELECT invite FROM address_card_steps WHERE card_handle = ?`, m.message_handle)
    if (steps.length > 0) {
      const waiting = steps.map((st) => head.deliveries.find((x) => x.invite === st.invite && x.state === "sending")).filter((x): x is address.DeliveryRecord => x !== undefined)
      if (m.status === "ERROR" || m.status === "DECLINED") return waiting.forEach((d) => this.record(d.invite, "failed", m.message_handle))
      if (m.status !== "SENT" && m.status !== "DELIVERED") return
      this.sqlStore.exec(`INSERT INTO address_card_sent (at) VALUES (?)`, Date.now())
      // Rows go before the awaits, so a duplicate status (SENT then DELIVERED) releases nothing twice.
      this.sqlStore.exec(`DELETE FROM address_card_steps WHERE card_handle = ?`, m.message_handle)
      let first = true
      for (const d of waiting) {
        const now = this.boundEngine!.currentState
        // A number that opted out after the card (STOP) gets no text.
        if (now.suppression) {
          this.record(d.invite, "suppressed", null)
          continue
        }
        const o = await this.step(now, d, "text", first)
        first = false
        this.record(d.invite, o.state, o.provider_id)
      }
      return
    }
    const d = head.deliveries.find((x) => x.provider_id === m.message_handle)
    const state = m.status === "DELIVERED" ? "delivered" : m.status === "SENT" ? "sent" : m.status === "ERROR" || m.status === "DECLINED" ? "failed" : null
    if (d && state) this.submitSystem("address.delivery.record", { invite: d.invite, state, provider_id: m.message_handle }, `status:${m.message_handle}:${state}`)
  }

  protected maySubscribe(): boolean {
    return false
  }

  protected read(_head: address.AddressHead, op: string, _params: unknown, _principal: Principal): ReadResult {
    return { ok: false, code: "validation.invalid", message: `no client reads on addresses (${op})` }
  }
}
