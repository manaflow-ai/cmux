import { describe, expect, it } from "vitest"
import { reactionEquals } from "../src/conversation/validate.ts"
import { fanOut, SYSTEM_ACTOR, type ConversationHead, type DeliveryState, type InviteStatus, type Op, type ReactionKind } from "../src/conversation/index.ts"
import { CoreHost, human, Rng, text } from "./support/harness.ts"
import { ALICE, BOB, CAROL, CHIEF, groupHead, tokenHash } from "./support/cloud.ts"

const SEEDS = Number(process.env.CONVERSATION_SEEDS ?? 300)
const STEPS = 150
const ADDRESSES = [1, 2, 3].map((n) => `addr_${"0".repeat(25)}${n}`)
const INVITES = [1, 2, 3, 4, 5, 6].map((n) => `inv_${"0".repeat(25)}${n}`)
const USERS = [ALICE, BOB, CAROL, "user_dave"]
const REACTIONS: Array<ReactionKind> = [{ tapback: "love" }, { tapback: "laugh" }, { emoji: "🎉" }]
const DELIVERY: Array<DeliveryState> = ["queued", "sent", "delivered", "bounced", "complained"]

const randomOp = (rng: Rng, host: CoreHost, key: string): Op => {
  const messageId = host.messages.length === 0 || rng.below(8) === 0 ? "msg_unknown" : rng.pick(host.messages).id
  const reaction = rng.pick(REACTIONS)
  const partIndex = rng.below(2)
  switch (rng.below(16)) {
    case 0:
    case 1:
    case 2: {
      const mention = rng.below(3) === 0 ? [{ start: 0, length: 1, mention: rng.pick([CHIEF, BOB, ALICE]) }] : undefined
      return { kind: "message.send", client_msg_id: key, parts: Array.from({ length: 1 + rng.below(2) }, () => ({ ...text("x"), ...(mention ? { runs: mention } : {}) })) }
    }
    case 3:
      return { kind: "message.edit", message_id: messageId, parts: [text("edited")] }
    case 4:
      return { kind: "message.retract", message_id: messageId }
    case 5:
      return { kind: "reaction.add", message_id: messageId, part_index: partIndex, reaction }
    case 6:
      return { kind: "reaction.remove", message_id: messageId, part_index: partIndex, reaction }
    case 7:
      return { kind: "read_cursor.set", seq: rng.below(host.head.last_seq + 2) }
    case 8:
      return { kind: "title.set", title: `title ${rng.below(100)}` }
    case 9:
      return { kind: "participants.add", participant: human(rng.pick(USERS), "Someone") }
    case 10:
      return { kind: "participants.remove", participant: rng.pick([...USERS, CHIEF, ...ADDRESSES]) }
    case 11: {
      const index = rng.below(INVITES.length)
      return {
        kind: "invite.create",
        invite_id: INVITES[index]!,
        address: rng.pick(ADDRESSES),
        channel: rng.pick(["email", "email", "email", "sms"] as const),
        display_name: "Guest",
        token_hash: tokenHash(`secret-${index}`),
        locale: "en",
        copy_variant: "A"
      }
    }
    case 12:
      return { kind: "invite.revoke", invite_id: rng.pick(INVITES) }
    case 13: {
      // Mostly an open invite's token, so accepts and approvals actually happen.
      const open = (host.head.invites ?? []).filter((invite) => invite.status === "pending")
      const index = open.length > 0 && rng.below(4) !== 0 ? INVITES.indexOf(rng.pick(open).id) : rng.below(INVITES.length)
      return { kind: "invite.accept", token_hash: tokenHash(`secret-${index}`), display_name: "Joiner" }
    }
    case 14:
      return { kind: "invite.delivery.report", invite_id: rng.pick(INVITES), delivery: { state: rng.pick(DELIVERY) } }
    default:
      return rng.below(3) !== 0
        ? { kind: "invite.approve_join", invite_id: rng.pick(INVITES), ...(rng.below(4) === 0 ? { approve: false } : {}) }
        : { kind: "conversation.settings.set", agent_budget: { turns: 1 + rng.below(4), gap_ms: rng.below(3000) } }
  }
}

const TERMINAL: ReadonlySet<InviteStatus> = new Set(["accepted", "revoked", "expired"])

describe("conversation reducer under random op sequences", () => {
  it(`keeps the invariants (${SEEDS} seeds x ${STEPS} steps)`, () => {
    let commits = 0
    let accepts = 0
    let wakes = 0
    let pendingApprovals = 0
    for (let seed = 1; seed <= SEEDS; seed++) {
      const rng = new Rng(BigInt(seed))
      const host = new CoreHost(groupHead())
      host.budget = rng.below(2) === 0
      const acceptedBy = new Map<string, string>()
      for (let step = 0; step < STEPS; step++) {
        const where = `seed ${seed} step ${step}`
        const actor = rng.pick([ALICE, BOB, CAROL, "user_dave", CHIEF, ...ADDRESSES, SYSTEM_ACTOR])
        const key = `k${seed}-${step}`
        const op = randomOp(rng, host, key)
        const before: ConversationHead = host.head
        const wasCurrent = before.participants.some((p) => p.id === actor && p.left_at === undefined)
        const request = host.request(actor, key, op, rng.below(2) === 0 ? { actor_addresses: ADDRESSES } : {})
        const result = host.run(actor, key, op, request)
        if (rng.below(5) === 0) host.advance(rng.below(3) === 0 ? 3 * 24 * 3600_000 : 1_500)
        if (!result.ok) {
          expect(host.head, `${where}: a reject changes nothing`).toBe(before)
          if (actor.startsWith("addr_") && wasCurrent && op.kind !== "invite.accept" && op.kind !== "invite.delivery.report") {
            expect(result.code, where).toBe("address_cannot_act")
          }
          continue
        }
        commits++
        const { commit } = result
        expect(commit.head.rev, `${where}: rev +1`).toBe(before.rev + 1)
        expect(actor.startsWith("addr_"), `${where}: a address committed`).toBe(false)
        if (op.kind !== "invite.accept" && op.kind !== "invite.delivery.report") expect(wasCurrent, `${where}: outsider committed ${op.kind}`).toBe(true)
        if (op.kind === "message.send") {
          expect(commit.head.last_seq).toBe(before.last_seq + 1)
          expect(commit.message?.seq).toBe(commit.head.last_seq)
          wakes += fanOut({ before, request, commit }).wakes.length
        } else {
          expect(commit.head.last_seq).toBe(before.last_seq)
        }
        // Invites: terminal states never change; an invite is accepted at most once, by one user.
        for (const invite of commit.head.invites ?? []) {
          const old = before.invites?.find((candidate) => candidate.id === invite.id)
          if (old && TERMINAL.has(old.status)) expect(invite.status, `${where}: ${invite.id} left ${old.status}`).toBe(old.status)
          if (invite.status === "pending_approval" && old?.status === "pending") pendingApprovals++
          if (invite.status === "accepted") {
            if (!acceptedBy.has(invite.id)) {
              acceptedBy.set(invite.id, invite.accepted_by!)
              accepts++
            }
            expect(invite.accepted_by, `${where}: second accept`).toBe(acceptedBy.get(invite.id))
          }
          if (old) expect(DELIVERY_RANK_OF(invite.delivery.state) >= DELIVERY_RANK_OF(old.delivery.state), where).toBe(true)
        }
      }
      const head = host.head
      expect(new Set(head.participants.map((p) => p.id)).size, `seed ${seed}: unique ids`).toBe(head.participants.length)
      expect(head.participants.filter((p) => p.role === "owner" && p.left_at === undefined).length, `seed ${seed}: owners`).toBeLessThanOrEqual(1)
      host.messages.forEach((message, index) => {
        expect(message.seq, `seed ${seed}: seq dense`).toBe(index + 1)
        expect(message.author.startsWith("addr_"), `seed ${seed}: address authored`).toBe(false)
        message.reactions.forEach((reaction, position) => {
          expect(reaction.part_index).toBeLessThan(message.parts.length)
          const duplicate = message.reactions
            .slice(0, position)
            .some((earlier) => earlier.author === reaction.author && earlier.part_index === reaction.part_index && reactionEquals(earlier.kind, reaction.kind))
          expect(duplicate, `seed ${seed}: duplicate reaction`).toBe(false)
        })
      })
      for (const [participant, seq] of Object.entries(head.read_cursors)) {
        expect(seq, `seed ${seed}: cursor past last_seq (${participant})`).toBeLessThanOrEqual(head.last_seq)
      }
    }
    // The runs must reach the interesting paths, or the invariants are vacuous.
    expect(commits).toBeGreaterThan(SEEDS * 20)
    expect(accepts).toBeGreaterThan(SEEDS / 10)
    expect(pendingApprovals).toBeGreaterThan(SEEDS / 10)
    expect(wakes).toBeGreaterThan(0)
  })

  it("read cursors never move backwards across a sequence", () => {
    for (let seed = 1; seed <= 50; seed++) {
      const rng = new Rng(BigInt(seed + 10_000))
      const host = new CoreHost(groupHead())
      const seen = new Map<string, number>()
      for (let step = 0; step < 100; step++) {
        const actor = rng.pick([ALICE, BOB, CHIEF])
        const key = `r${step}`
        const op: Op = rng.below(2) === 0 ? { kind: "message.send", client_msg_id: key, parts: [text("x")] } : { kind: "read_cursor.set", seq: rng.below(host.head.last_seq + 1) }
        host.run(actor, key, op)
        for (const [participant, seq] of Object.entries(host.head.read_cursors)) {
          expect(seq).toBeGreaterThanOrEqual(seen.get(participant) ?? 0)
          seen.set(participant, seq)
        }
      }
    }
  })
})

const DELIVERY_RANK_OF = (state: DeliveryState): number => ({ queued: 0, sent: 1, delivered: 2, bounced: 3, failed: 3, suppressed: 3, refused_env: 3, complained: 4 })[state]
