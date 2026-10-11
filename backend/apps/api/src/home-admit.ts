import type { CloudOpDef } from "@cmux/protocol"
import type { Domain, Principal, Reject } from "@cmux/ownership"
import { admit } from "./domains/common.ts"

/**
 * Wraps a lane 15 Home domain with the catalog check every cloud owner applies: the op must
 * belong to this owner, the principal kind must be allowed, and an install's grant (resolved by
 * the Worker into `grant_classes`) must cover the op's risk. System principals (outbox
 * deliveries between Home objects) skip the catalog: their ops are internal and the domain
 * checks them. The domain's own authorize runs after.
 */
export const withAdmit = <S>(owner: CloudOpDef["owner"], domain: Domain<S>): Domain<S> => ({
  ...domain,
  authorize: (state, op, params, principal): Reject | undefined => {
    if (principal.kind !== "system") {
      const refused = admit(owner, op, principal, grantClasses, Date.now())
      if (refused) return refused
    }
    return domain.authorize?.(state, op, params, principal)
  }
})

/** An install's grant as the Worker resolved it (withGrantClasses); none means refuse. */
export const grantClasses = (p: Principal) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined)
