import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// HomeStore snapshots become the MessagesLab actions MessagesLab's own
/// engine dispatches for the same events (intent mapping, plan step 2).
@Suite struct HomeDiffTests {
    let me = Fixture2.me, them = Fixture2.them

    func plan(_ old: [TranscriptItem], _ new: [TranscriptItem], aliases: [IdempotencyKey: ID] = [:],
              oldSummary: ConversationSummary? = Fixture2.summary(), newSummary: ConversationSummary? = Fixture2.summary()) -> HomeDiff {
        HomeDiff.plan(old: old, new: new, oldSummary: oldSummary, newSummary: newSummary, aliases: aliases, me: me)
    }

    @Test func theirNewMessageIsAReceive() {
        let base = Fixture2.history(5)
        let d = plan(base, base + [Fixture2.item(6, them, "Hello")])
        #expect(d.actions.map(HomeDiff.describe) == ["receive k6 agent_chief"])
        #expect(!d.rebuild)
    }

    @Test func myMessageFromAnotherClientIsMessagesLabsExternalInsert() {
        // Chief or the CLI wrote as me: a receive with my sender id, which
        // MessagesWindowView animates with Springs.insert (no morph).
        let base = Fixture2.history(5)
        let d = plan(base, base + [Fixture2.item(6, me, "From the CLI")])
        #expect(d.actions.map(HomeDiff.describe) == ["receive k6 user_me"])
    }

    @Test func mySendsEchoOnlyChangesItsStatus() {
        let base = Fixture2.history(5)
        let key = IdempotencyKey("cmk_send")
        let aliases = [key: "local-1"]
        var pending = TranscriptItem(key: key, seq: nil, author: me, parts: [.text("Hi")], createdAt: Fixture2.start, delivery: .sending)
        #expect(plan(base, base + [pending], aliases: aliases).actions.isEmpty, "the projection already shows it as sending")
        pending.seq = 6
        pending.delivery = .committed
        let delivered = plan(base + [pending], base + [pending], aliases: aliases)
        #expect(delivered.actions.isEmpty, "unchanged")
        let committed = plan(base, base + [pending], aliases: aliases)
        #expect(committed.actions.map(HomeDiff.describe).first?.hasPrefix("status local-1 delivered") == true)
        let read = plan(base + [pending], base + [pending], aliases: aliases, newSummary: Fixture2.summary(lastSeq: 6, read: 6))
        #expect(read.actions.map(HomeDiff.describe).first?.hasPrefix("status local-1 read") == true)
    }

    @Test func anOlderPageIsAPrepend() {
        let all = Fixture2.history(10)
        let d = plan(Array(all[4...]), all)
        #expect(d.actions.map(HomeDiff.describe) == ["prepend [\"k1\", \"k2\", \"k3\", \"k4\"]"])
    }

    @Test func aRemovedOrRewrittenMessageRebuilds() {
        let base = Fixture2.history(5)
        #expect(plan(base, Array(base.dropLast())).rebuild)
        var changed = base
        changed[2].parts = [.text("Different")]
        #expect(plan(base, changed).rebuild, "content changed in place without an edit")
        let bulk = base + (6...10).map { Fixture2.item(Seq($0), them, "x") }
        #expect(plan(base, bulk).rebuild, "a refetch is not five receive transitions")
    }

    @Test func editsRetractsAndTapbacks() {
        let base = Fixture2.history(5)
        var next = base
        next[1].editedAt = Fixture2.start
        next[1].parts = [.text("Edited text")]
        next[2].isRetracted = true
        next[2].parts = []
        next[3].reactions = [CmuxHomeCore.Reaction(author: them, partIndex: 0, kind: .tapback(.love))]
        #expect(plan(base, next).actions.map(HomeDiff.describe) == [
            "edit k2 Edited text", "unsend k3", "react k4:0 tapback(\"love\") agent_chief",
        ])
        var off = next
        off[3].reactions = []
        #expect(plan(next, off).actions.map(HomeDiff.describe) == ["react k4:0 tapback(\"love\") agent_chief"], "toggles off")
    }

    @Test func typingFollowsTheStoreAndNeverShowsMine() {
        #expect(HomeDiff.typing(current: [], wanted: [them, me], me: me).map(HomeDiff.describe) == ["typing agent_chief true"])
        #expect(HomeDiff.typing(current: ["agent_chief"], wanted: [], me: me).map(HomeDiff.describe) == ["typing agent_chief false"])
    }

    @Test func statusMapsDeliveryAndReadCursors() {
        let mine = Fixture2.item(4, me, "x")
        #expect(HomeMapping.status(mine, me: me, summary: Fixture2.summary(lastSeq: 4)).map { "\($0)" }?.hasPrefix("delivered") == true)
        #expect(HomeMapping.status(mine, me: me, summary: Fixture2.summary(lastSeq: 4, read: 4)).map { "\($0)" }?.hasPrefix("read") == true)
        #expect(HomeMapping.status(Fixture2.item(4, them, "x"), me: me, summary: nil) == nil)
        var failed = mine
        failed.delivery = .notDelivered(.notAuthorized)
        #expect(HomeMapping.status(failed, me: me, summary: nil) == .failed(reason: nil))
    }
}
