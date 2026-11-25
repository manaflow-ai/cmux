import { describe, expect, it } from "vitest"
import { CoreHost } from "./support/harness.ts"
import { ADDRESS, ADDRESS2, ALICE, CHIEF, groupHead, INV2, inviteOp, tokenHash } from "./support/cloud.ts"

/**
 * Chief channels (plans/cmux-next/chief-channels-DESIGN.md gap 3): a Chief's invite runs as that Chief, not its
 * owner. Invites stay a person's act, with one exception: the channel's own Chief (the head's `channel_chief`)
 * invites into its channel, on its owner's word (the Worker's effect policy). Any other agent, in a channel or
 * in a plain group, is refused as before.
 */
describe("invite.create by a channel's own Chief", () => {
  it("lets the channel's Chief invite and records it as the inviter", () => {
    const host = new CoreHost(groupHead({ channel_chief: CHIEF }))
    const made = host.run(CHIEF, "i1", inviteOp())
    expect(made.ok).toBe(true)
    expect(host.head.invites?.[0]).toMatchObject({ address: ADDRESS, invited_by: CHIEF })
  })

  it("refuses an agent that is not the channel's Chief", () => {
    const host = new CoreHost(groupHead({ channel_chief: "agent_otherchief" }))
    expect(host.run(CHIEF, "i1", inviteOp())).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("refuses a Chief in a group that is no channel", () => {
    const host = new CoreHost(groupHead())
    expect(host.run(CHIEF, "i1", inviteOp())).toMatchObject({ ok: false, code: "forbidden" })
  })

  it("still lets the people invite in a channel", () => {
    const host = new CoreHost(groupHead({ channel_chief: CHIEF }))
    expect(host.run(ALICE, "i2", inviteOp({ invite_id: INV2, address: ADDRESS2, token_hash: tokenHash("s2") })).ok).toBe(true)
  })
})
