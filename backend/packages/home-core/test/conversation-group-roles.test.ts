import { describe, expect, it } from "vitest"
import type { ConversationHead } from "../src/conversation/types.ts"
import { Group } from "./support/group.ts"

/**
 * Roles in a cloud group (plans/cmux-next/home-dm-group-chats/DESIGN.md section 4): owner, admin,
 * member and read_only, checked in the conversation's own owner on every op. A role is granted only
 * at or below the granter's own (only the owner makes admins), a removed person loses every right
 * at once, and a banned person cannot be put back until unbanned.
 */
const ANN = "user_ann"
const BEN = "user_ben"
const CAT = "user_cat"
const DEE = "user_dee"
const EVE = "user_eve"

const roleOf = (group: Group, id: string) => (group.host.state as ConversationHead).participants.find((p) => p.id === id && p.left_at === undefined)?.role
const current = (group: Group, id: string) => (group.host.state as ConversationHead).participants.some((p) => p.id === id && p.left_at === undefined)

describe("group roles", () => {
  it("the owner makes an admin, who then removes a member but never the owner", () => {
    const group = new Group(ANN, [BEN, CAT, DEE])
    expect(group.code(ANN, "participants.set_role", { participant: BEN, role: "admin" })).toBe("ok")
    expect(roleOf(group, BEN)).toBe("admin")
    expect(group.code(BEN, "participants.remove", { participant: CAT })).toBe("ok")
    expect(current(group, CAT)).toBe(false)
    expect(group.code(BEN, "participants.remove", { participant: ANN })).toBe("forbidden")
    // A member removes nobody but itself.
    expect(group.code(DEE, "participants.remove", { participant: BEN })).toBe("forbidden")
  })

  it("only the owner makes admins, and an admin never changes another admin", () => {
    const group = new Group(ANN, [BEN, CAT, DEE])
    expect(group.code(ANN, "participants.set_role", { participant: BEN, role: "admin" })).toBe("ok")
    expect(group.code(BEN, "participants.set_role", { participant: CAT, role: "admin" })).toBe("forbidden")
    expect(group.code(ANN, "participants.set_role", { participant: CAT, role: "admin" })).toBe("ok")
    expect(group.code(BEN, "participants.set_role", { participant: CAT, role: "member" })).toBe("forbidden")
    expect(group.code(BEN, "participants.set_role", { participant: DEE, role: "read_only" })).toBe("ok")
    expect(group.code(DEE, "participants.set_role", { participant: DEE, role: "member" })).toBe("forbidden")
    // Nobody is made owner by set_role: that is ownership.transfer.
    expect(group.code(ANN, "participants.set_role", { participant: BEN, role: "owner" })).toBe("invalid_role")
  })

  it("a read-only member reads and leaves but never writes", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.send(ANN, "hello").ok).toBe(true)
    expect(group.code(ANN, "participants.set_role", { participant: CAT, role: "read_only" })).toBe("ok")
    expect(group.send(CAT, "can I talk?")).toMatchObject({ ok: false, code: "read_only" })
    expect(group.code(CAT, "title.set", { title: "Mine" })).toBe("read_only")
    expect(group.add(CAT, DEE)).toBe("read_only")
    expect(group.code(CAT, "read_cursor.set", { seq: 1 })).toBe("ok")
    expect(group.code(CAT, "participants.remove", { participant: CAT })).toBe("ok")
  })

  it("a grant is never above the granter: a member adds members, only the owner adds an admin", () => {
    const group = new Group(ANN, [BEN])
    expect(group.add(BEN, CAT)).toBe("ok")
    expect(roleOf(group, CAT)).toBe("member")
    expect(group.add(BEN, DEE, "admin")).toBe("forbidden")
    expect(group.add(BEN, DEE, "read_only")).toBe("ok")
    expect(roleOf(group, DEE)).toBe("read_only")
    expect(group.add(ANN, EVE, "admin")).toBe("ok")
    expect(roleOf(group, EVE)).toBe("admin")
  })

  it("the owner hands the group to a member and becomes an admin", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.code(BEN, "ownership.transfer", { participant: CAT })).toBe("forbidden")
    expect(group.code(ANN, "ownership.transfer", { participant: "user_nobody" })).toBe("unknown_participant")
    expect(group.code(ANN, "ownership.transfer", { participant: BEN })).toBe("ok")
    expect(roleOf(group, BEN)).toBe("owner")
    expect(roleOf(group, ANN)).toBe("admin")
    expect((group.host.state as ConversationHead).participants.filter((p) => p.role === "owner")).toHaveLength(1)
  })

  it("an owner who leaves hands the group to an admin before a member", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.code(ANN, "participants.set_role", { participant: CAT, role: "admin" })).toBe("ok")
    expect(group.code(ANN, "participants.remove", { participant: ANN })).toBe("ok")
    expect(roleOf(group, CAT)).toBe("owner")
    expect(roleOf(group, BEN)).toBe("member")
  })

  it("a removed member loses every right at once", () => {
    const group = new Group(ANN, [BEN, CAT])
    const first = group.send(CAT, "hi")
    expect(first.ok).toBe(true)
    expect(group.code(ANN, "participants.remove", { participant: CAT })).toBe("ok")
    expect(group.send(CAT, "still here?")).toMatchObject({ ok: false, code: "not_participant" })
    expect(group.code(CAT, "read_cursor.set", { seq: 1 })).toBe("not_participant")
    expect(group.code(CAT, "title.set", { title: "x" })).toBe("not_participant")
    expect(group.add(CAT, DEE)).toBe("not_participant")
    expect(group.code(CAT, "participants.remove", { participant: BEN })).toBe("not_participant")
  })

  it("a banned person cannot be added back until an admin unbans them", () => {
    const group = new Group(ANN, [BEN, CAT])
    expect(group.code(ANN, "participants.set_role", { participant: BEN, role: "admin" })).toBe("ok")
    expect(group.code(ANN, "participants.remove", { participant: CAT, ban: true })).toBe("ok")
    expect(group.add(ANN, CAT)).toBe("banned")
    expect(group.add(BEN, CAT)).toBe("banned")
    // A member cannot unban.
    expect(group.add(ANN, DEE)).toBe("ok")
    expect(group.code(DEE, "participants.unban", { participant: CAT })).toBe("forbidden")
    expect(group.code(BEN, "participants.unban", { participant: CAT })).toBe("ok")
    expect(group.add(BEN, CAT)).toBe("ok")
  })
})
