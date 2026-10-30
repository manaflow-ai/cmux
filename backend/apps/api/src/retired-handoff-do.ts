import { DurableObject } from "cloudflare:workers"

// Keep the deployed class identities and their stored data. Wrangler still names these
// classes in its bindings and migrations; removing data needs a separate migration.
// No HTTP route or RPC operation reaches the retired hand-off store.
export class HandoffDO extends DurableObject {
  // An old index-retry alarm may still fire after cutover. Leave its stored rows untouched.
  async alarm(): Promise<void> {}
}

export class HandoffIndexDO extends DurableObject {}
