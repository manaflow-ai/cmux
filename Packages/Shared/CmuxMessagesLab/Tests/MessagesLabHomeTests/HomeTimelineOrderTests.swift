import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home chat's order rules (plans/cmux-next/home-chat-pipeline-DESIGN.md section 2): committed
/// messages by seq, then my pending sends in send order, then every running reply in the order its
/// turn began. After every pass the view shows exactly that order, and each reply shows in one
/// bubble. One test per bug (B1-B4 in the design's bug list), on the real view and HomeStore.
@MainActor @Suite(.serialized) struct HomeTimelineOrderTests {
    static let t = HomeChatRig.tag

    /// B1. I send while the reply streams; the owner posts the reply before it commits my send.
    @Test func replyPostedBeforeMySendCommits() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let reply = "\(Self.t)reply: the switch reads one state now"
        rig.delta("r1", seq: 0, "\(Self.t)reply: the switch")
        rig.frame()
        rig.delta("r1", seq: 1, " reads one state now")
        rig.frame()
        #expect(rig.bubbles() == [reply], "streaming")

        await rig.holdSends()
        let mine = "\(Self.t)mine: keep the old path behind a flag"
        #expect(await rig.send(mine) == nil)
        #expect(rig.bubbles() == [mine, reply], "my send shows above the running reply")

        // The owner commits the reply first: it has the lower seq.
        #expect(await rig.post(reply, key: IdempotencyKey("r1")))
        rig.frame()
        #expect(rig.storeItems() == [reply, mine], "store order")
        #expect(rig.bubbles() == rig.storeItems(), "the view shows the owner's order once the reply is posted")

        await rig.releaseSends()
        rig.frame()
        #expect(rig.storeItems() == [reply, mine])
        #expect(rig.bubbles() == rig.storeItems(), "the view shows the owner's order once my send commits")
    }

    /// B2. Someone's message commits while my send is still pending.
    @Test func theirMessageWhileMySendIsPending() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        await rig.holdSends()
        let mine = "\(Self.t)mine: is the nightly out?"
        #expect(await rig.send(mine) == nil)
        #expect(rig.bubbles() == [mine])

        let theirs = "\(Self.t)theirs: the CLI posted this first"
        #expect(await rig.post(theirs, key: .make()))
        rig.frame()
        #expect(rig.storeItems() == [theirs, mine], "store order")
        #expect(rig.bubbles() == rig.storeItems(), "the committed message shows above my pending send")

        await rig.releaseSends()
        rig.frame()
        #expect(rig.bubbles() == [theirs, mine])
    }

    /// B3. Two replies run at once in one conversation: two bubbles, each whole, in begin order.
    @Test func twoRepliesStreamAtOnce() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        rig.delta("r1", seq: 0, "\(Self.t)first: one")
        rig.frame()
        rig.delta("r2", seq: 0, "\(Self.t)second: one")
        rig.frame()
        rig.delta("r1", seq: 1, " two")
        rig.frame()
        rig.delta("r2", seq: 1, " two")
        rig.frame()
        rig.delta("r1", seq: 2, " three")
        rig.frame()
        #expect(rig.bubbles() == ["\(Self.t)first: one two three", "\(Self.t)second: one two"], "both replies, in begin order")

        #expect(await rig.post("\(Self.t)first: one two three", key: IdempotencyKey("r1")))
        rig.frame()
        #expect(rig.bubbles() == ["\(Self.t)first: one two three", "\(Self.t)second: one two"], "the first posted, the second still streams")
    }

    /// B4. A run ends `done`, the next run starts before its reply lands: the reply never leaves the screen.
    @Test func aNewTurnKeepsTheLastReplyUntilItLands() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let first = "\(Self.t)first reply, whole"
        rig.run("r1", "running")
        rig.delta("r1", seq: 0, first)
        rig.frame()
        rig.run("r1", "done")
        rig.frame()
        #expect(rig.bubbles() == [first], "done, waiting for its reply")

        rig.run("r2", "running")
        rig.delta("r2", seq: 0, "\(Self.t)second")
        rig.frame()
        #expect(rig.bubbles() == [first, "\(Self.t)second"], "the next turn starts: the first reply stays, the second streams below")

        #expect(await rig.post(first, key: IdempotencyKey("r1")))
        rig.frame()
        #expect(rig.bubbles() == [first, "\(Self.t)second"], "the first reply landed in its place")
    }
}
