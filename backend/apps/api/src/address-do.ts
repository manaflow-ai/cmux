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

  protected maySubscribe(): boolean {
    return false
  }

  protected read(_head: address.AddressHead, op: string, _params: unknown, _principal: Principal): ReadResult {
    return { ok: false, code: "validation.invalid", message: `no client reads on addresses (${op})` }
  }
}
