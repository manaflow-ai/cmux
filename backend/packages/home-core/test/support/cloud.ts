import { createHash } from "node:crypto"
import { create, dmConversationId, type ConversationHead, type InviteCreateParams } from "../../src/conversation/index.ts"
import { agent, human, NOW } from "./harness.ts"

export const ALICE = "user_alice"
export const BOB = "user_bob"
export const CAROL = "user_carol"
export const CHIEF = "agent_alicechief"
export const ADDRESS = `addr_${"0".repeat(25)}1`
export const ADDRESS2 = `addr_${"0".repeat(25)}2`
export const INV = `inv_${"0".repeat(25)}1`
export const INV2 = `inv_${"0".repeat(25)}2`

/** sha256 base64url, as `hashInviteSecret`. */
export const tokenHash = (secret: string) => createHash("sha256").update(secret).digest("base64url")

export const groupHead = (extra: Partial<Parameters<typeof create>[0]> = {}): ConversationHead => {
  const result = create({
    id: "conv_GROUP",
    actor: ALICE,
    title: "Team",
    participants: [human(ALICE, "Alice"), human(BOB, "Bob"), agent(CHIEF, ALICE)],
    now: NOW,
    kind: "group",
    ...extra
  })
  if (!result.ok) throw new Error(result.code)
  return result.head
}

export const chiefHead = (): ConversationHead => {
  const result = create({ id: "conv_CHIEF", actor: ALICE, title: "Chief", participants: [human(ALICE, "Alice"), agent(CHIEF, ALICE)], now: NOW, kind: "chief" })
  if (!result.ok) throw new Error(result.code)
  return result.head
}

export const dmHead = (peer = BOB): ConversationHead => {
  const peerRecord = peer.startsWith("addr_") ? { id: peer, kind: "address" as const, display_name: "bob@" } : human(peer, "Bob")
  const result = create({ id: dmConversationId(ALICE, peer), actor: ALICE, title: "", participants: [human(ALICE, "Alice"), peerRecord], now: NOW, kind: "dm" })
  if (!result.ok) throw new Error(result.code)
  return result.head
}

export const inviteOp = (overrides: Partial<InviteCreateParams> = {}): InviteCreateParams => ({
  kind: "invite.create",
  invite_id: INV,
  address: ADDRESS,
  channel: "email",
  display_name: "Dana",
  token_hash: tokenHash("secret-1"),
  locale: "en",
  copy_variant: "A",
  ...overrides
})
