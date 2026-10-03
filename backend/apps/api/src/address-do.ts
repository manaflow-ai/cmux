import type { Domain, Principal } from "@cmux/ownership"
import { address } from "@cmux/home-core"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"

/**
 * AddressDO, one per invited address (home-messaging.md sections 3 and 9, renamed from
 * ContactDO): the only copy of the raw address, suppression, per-recipient limits and the
 * delivery record, run by lane 15's pure domain.
 *
 * Stage A: the domain is hosted and its ops commit. Provider sends (the external effect after
 * address.deliver, the invite secret stash, the vCard-first sequence and the provider webhooks)
 * land in stage C behind a reviewed PR; until then no message leaves this object.
 */
export class AddressDO extends OwnerDO<address.AddressHead> {
  constructor(ctx: DurableObjectState, env: Env) {
    // No client subscribes: subscribers would see the raw address.
    super(ctx, env, address.addressDomain as Domain<address.AddressHead>, "address")
  }

  /**
   * RPC from the Worker before invite.create commits: the invite secret, kept only here (the
   * object that sends it) and deleted after the send or 24 h, whichever comes first.
   */
  async stashSecret(address: string, invite: string, secret: string, expiresAt: number): Promise<void> {
    this.bind(address)
    this.secrets()
    this.sqlStore.exec(`INSERT INTO address_secrets (invite, secret, expires_at) VALUES (?, ?, ?) ON CONFLICT (invite) DO NOTHING`, invite, secret, expiresAt)
    this.scheduleAlarm()
  }

  /** The stashed secret of an invite, if still there (stage C sends read it once, then delete it). */
  protected stashedSecret(invite: string): string | undefined {
    this.secrets()
    return this.sqlStore.exec<{ secret: string }>(`SELECT secret FROM address_secrets WHERE invite = ? AND expires_at > ?`, invite, Date.now())[0]?.secret
  }

  private secrets() {
    this.sqlStore.exec(`CREATE TABLE IF NOT EXISTS address_secrets (invite TEXT PRIMARY KEY, secret TEXT NOT NULL, expires_at INTEGER NOT NULL)`)
  }

  protected nextWakeAt(_head: address.AddressHead, _now: number): number | null {
    this.secrets()
    const next = this.sqlStore.exec<{ at: number | null }>(`SELECT MIN(expires_at) AS at FROM address_secrets`)[0]?.at
    return next === null || next === undefined ? null : Number(next)
  }

  protected async onWake(now: number): Promise<void> {
    this.secrets()
    this.sqlStore.exec(`DELETE FROM address_secrets WHERE expires_at <= ?`, now)
  }

  protected maySubscribe(): boolean {
    return false
  }

  protected read(_head: address.AddressHead, op: string, _params: unknown, _principal: Principal): ReadResult {
    return { ok: false, code: "validation.invalid", message: `no client reads on addresses (${op})` }
  }
}
