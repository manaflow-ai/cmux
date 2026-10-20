import { createHash } from "node:crypto"
import { describe, expect, it } from "vitest"
import type { ConversationHead } from "../src/conversation/types.ts"
import { Group } from "./support/group.ts"

/**
 * Link grants (plans/cmux-next/home-dm-group-chats/DESIGN.md section 2.1): a member mints an
 * unguessable link tied to a role at most its own; anyone signed in who holds the secret joins
 * with that role, while the link is open, unexpired and has uses left. The conversation stores
 * only sha256(sha256(secret)); a redeem passes proof = sha256(secret), as `invite.accept` does.
 * Revoking the link, or removing or demoting the member who made it, closes it at once.
 */
const ANN = "user_ann"
const BEN = "user_ben"
const CAT = "user_cat"
const OUT1 = "user_out1"
const OUT2 = "user_out2"

const sha = (text: string) => createHash("sha256").update(text).digest("base64url")
let next = 0
/** Mints a grant as `actor`; returns the reject code or the secret's proof. */
const mint = (group: Group, actor: string, params: Record<string, unknown> = {}) => {
  const n = ++next
  const secret = `secret-${n}`
  const grantId = `grt_${String(n).padStart(26, "0")}`
  const code = group.code(actor, "grant.create", { grant_id: grantId, token_hash: sha(sha(secret)), ...params })
  return { code, grantId, proof: sha(secret) }
}
const redeem = (group: Group, who: string, proof: string) => group.code(who, "invite.accept", { proof })
const roleOf = (group: Group, id: string) => (group.host.state as ConversationHead).participants.find((p) => p.id === id && p.left_at === undefined)?.role

describe("link grants", () => {
  it("a member's link lets someone it never reached join as a member", () => {
    const group = new Group(ANN, [BEN])
    const link = mint(group, BEN)
    expect(link.code).toBe("ok")
    expect(redeem(group, OUT1, link.proof)).toBe("ok")
    expect(roleOf(group, OUT1)).toBe("member")
    const joined = (group.host.state as ConversationHead).participants.find((p) => p.id === OUT1)
    expect(joined?.added_by).toBe(BEN)
    // A wrong secret is an unknown invite, like any bad link.
    expect(redeem(group, OUT2, sha("guess"))).toBe("unknown_invite")
  })

  it("a link is never above its maker: read_only mints nothing, only the owner mints admin links", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.code(ANN, "participants.set_role", { participant: CAT, role: "read_only" })).toBe("ok")
    expect(mint(group, CAT).code).toBe("read_only")
    expect(mint(group, BEN, { role: "admin" }).code).toBe("forbidden")
    expect(mint(group, BEN, { role: "read_only" }).code).toBe("ok")
    const admin = mint(group, ANN, { role: "admin" })
    expect(admin.code).toBe("ok")
    expect(redeem(group, OUT1, admin.proof)).toBe("ok")
    expect(roleOf(group, OUT1)).toBe("admin")
  })

  it("a revoked link stops working; only its maker or someone above revokes it", () => {
    const group = new Group(ANN, [BEN, CAT])
    const link = mint(group, BEN)
    expect(group.code(CAT, "grant.revoke", { grant_id: link.grantId })).toBe("forbidden")
    expect(group.code(BEN, "grant.revoke", { grant_id: link.grantId })).toBe("ok")
    expect(redeem(group, OUT1, link.proof)).toBe("unknown_invite")
    const other = mint(group, BEN)
    expect(group.code(ANN, "grant.revoke", { grant_id: other.grantId })).toBe("ok")
    expect(redeem(group, OUT1, other.proof)).toBe("unknown_invite")
  })

  it("removing or demoting the maker closes its links at once", () => {
    const group = new Group(ANN, [BEN, CAT])
    const byBen = mint(group, BEN)
    const byCat = mint(group, CAT)
    expect(group.code(ANN, "participants.remove", { participant: BEN })).toBe("ok")
    expect(redeem(group, OUT1, byBen.proof)).toBe("unknown_invite")
    expect(group.code(ANN, "participants.set_role", { participant: CAT, role: "read_only" })).toBe("ok")
    expect(redeem(group, OUT2, byCat.proof)).toBe("unknown_invite")
    expect((group.host.state as ConversationHead).grants ?? []).toHaveLength(0)
  })

  it("a link ends after its uses and after it expires", () => {
    const group = new Group(ANN, [BEN])
    const once = mint(group, ANN, { max_uses: 1 })
    expect(redeem(group, OUT1, once.proof)).toBe("ok")
    expect(redeem(group, OUT2, once.proof)).toBe("unknown_invite")
    const soon = mint(group, ANN, { expires_in_hours: 1 })
    group.host.now += 2 * 3600_000
    expect(redeem(group, OUT2, soon.proof)).toBe("invite_expired")
  })

  it("a banned person cannot come back through a link", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.code(ANN, "participants.remove", { participant: CAT, ban: true })).toBe("ok")
    const link = mint(group, ANN)
    expect(redeem(group, CAT, link.proof)).toBe("banned")
  })

  it("someone already in the group keeps their role", () => {
    const group = new Group(ANN, [BEN])
    const link = mint(group, ANN, { role: "read_only" })
    expect(redeem(group, BEN, link.proof)).toBe("duplicate_participant")
    expect(roleOf(group, BEN)).toBe("member")
  })

  it("a link works in a large group", () => {
    const group = new Group(ANN, [BEN])
    for (let n = 0; n < 80; n++) expect(group.add(ANN, `user_bulk${n}`)).toBe("ok")
    const link = mint(group, `user_bulk70`)
    expect(link.code).toBe("ok")
    expect(redeem(group, OUT1, link.proof)).toBe("ok")
    expect(group.send(OUT1, "hi all").ok).toBe(true)
  })
})
