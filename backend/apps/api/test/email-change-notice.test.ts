import { idFactory, type Principal } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { confirmEnv } from "../src/domains/user-confirm.ts"
import { userDomain, type UserState } from "../src/domains/user.ts"

/**
 * Account-takeover defense (cx-44j.45): a verified-email change sends a notice to the old address,
 * and for 14 days security notices go to both the new and the previous verified address.
 */
const USER = "user_aaaaaaaaaaaaaaaaaaaa"
const DAY = 86_400_000
const session = (email: string, verified = true): Principal =>
  ({ identity: `session:${USER}`, kind: "session", user: USER, stack_user_id: "stack_1", team: "team_personal0000000000", email, email_verified: verified }) as Principal
let n = 0
const ensure = (s: UserState, p: Principal, now: number) => {
  const tx = `t${n++}`
  const r = userDomain.reduce(s, "user.ensure", {}, { principal: p, now, tx, newId: idFactory(tx) })
  if (!r.ok) throw new Error(r.message)
  return r
}
const mails = (outbox: ReadonlyArray<{ kind: string; payload: unknown }> | undefined) =>
  (outbox ?? []).filter((o) => o.kind === "mail.security_notice").map((o) => o.payload as { to: string; template: string })

describe("verified email change", () => {
  it("notifies the old verified address, never the new one, and keeps the old one for 14 days", () => {
    const t0 = 10 * DAY
    const first = ensure(userDomain.initial(), session("old@example.com"), t0)
    expect(mails(first.outbox)).toEqual([])
    const changed = ensure(first.state, session("new@example.com"), t0 + 1000)
    expect(mails(changed.outbox)).toEqual([expect.objectContaining({ to: "old@example.com", template: "email_changed" })])
    const s = changed.state
    expect(confirmEnv(s, "", t0 + 2000).emails).toEqual(["new@example.com", "old@example.com"])
    expect(confirmEnv(s, "", t0 + 1000 + 14 * DAY + 1).emails).toEqual(["new@example.com"])
    // The same email again is no change; an unverified new address keeps the old one as the only recipient.
    expect(mails(ensure(s, session("new@example.com"), t0 + 3000).outbox)).toEqual([])
    const unverified = ensure(first.state, session("other@example.com", false), t0 + 1000)
    expect(mails(unverified.outbox)).toEqual([expect.objectContaining({ to: "old@example.com" })])
    expect(confirmEnv(unverified.state, "", t0 + 2000).emails).toEqual(["old@example.com"])
  })

  it("a second change inside the window keeps the earliest address that was verified", () => {
    const t0 = 10 * DAY
    let s = ensure(userDomain.initial(), session("a@example.com"), t0).state
    s = ensure(s, session("b@example.com"), t0 + 1000).state
    const r = ensure(s, session("c@example.com"), t0 + 2000)
    // The takeover victim (a) keeps getting notices; b is told as well.
    expect(mails(r.outbox).map((m) => m.to).sort()).toEqual(["a@example.com", "b@example.com"])
    expect([...(confirmEnv(r.state, "", t0 + 3000).emails ?? [])].sort()).toEqual(["a@example.com", "b@example.com", "c@example.com"])
  })

  it("ignores letter case, keeps the earliest five addresses, and ignores an old token's claim right after a change", () => {
    const t0 = 10 * DAY
    let s = ensure(userDomain.initial(), session("Owner@Example.com"), t0).state
    // Case only: same mailbox, no notice, no second email per notice.
    const cased = ensure(s, session("owner@example.com"), t0 + 1000)
    expect(mails(cased.outbox)).toEqual([])
    expect(confirmEnv(cased.state, "", t0 + 2000).emails).toHaveLength(1)
    // A real change, then an older token still claiming the old address within 15 minutes: no flap.
    s = ensure(s, session("attacker@example.com"), t0 + 2000).state
    const stale = ensure(s, session("Owner@Example.com"), t0 + 3000)
    expect(stale.state.user?.email).toBe("attacker@example.com")
    expect(mails(stale.outbox)).toEqual([])
    // Many later changes never evict the owner's address, and the list stays bounded.
    for (let i = 0; i < 8; i++) s = ensure(s, session(`x${i}@example.com`), t0 + 20 * 60_000 * (i + 2)).state
    expect(s.previous_emails?.length).toBe(5)
    expect(s.previous_emails?.[0]?.email).toBe("Owner@Example.com")
    expect(confirmEnv(s, "", t0 + DAY).emails).toContain("Owner@Example.com")
  })
})
