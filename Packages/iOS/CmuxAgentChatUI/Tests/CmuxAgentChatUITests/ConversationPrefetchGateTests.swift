import Testing
@testable import CmuxAgentChatUI

@Suite("Conversation transcript prefetch")
struct ConversationPrefetchGateTests {
    @Test("a head window can page forward as its loaded tail approaches")
    func headWindowPagesForward() {
        var gate = ConversationPrefetchGate<String>()

        let tooFar = gate.shouldLoadAfter(hasMore: true, distance: 161, lastID: "50")
        let firstBoundary = gate.shouldLoadAfter(hasMore: true, distance: 160, lastID: "50")
        let duplicateBoundary = gate.shouldLoadAfter(hasMore: true, distance: 0, lastID: "50")
        let advancedBoundary = gate.shouldLoadAfter(hasMore: true, distance: 120, lastID: "100")
        #expect(!tooFar)
        #expect(firstBoundary)
        #expect(!duplicateBoundary)
        #expect(advancedBoundary)
    }

    @Test("both edge callbacks coalesce until their boundary identity advances")
    func callbacksCoalesceByBoundaryIdentity() {
        var gate = ConversationPrefetchGate<Int>()

        let firstHead = gate.shouldLoadBefore(hasMore: true, distance: 20, firstID: 100)
        let duplicateHead = gate.shouldLoadBefore(hasMore: true, distance: 0, firstID: 100)
        let advancedHead = gate.shouldLoadBefore(hasMore: true, distance: 80, firstID: 50)
        let firstTail = gate.shouldLoadAfter(hasMore: true, distance: 20, lastID: 150)
        let duplicateTail = gate.shouldLoadAfter(hasMore: true, distance: 0, lastID: 150)
        let advancedTail = gate.shouldLoadAfter(hasMore: true, distance: 80, lastID: 200)
        #expect(firstHead)
        #expect(!duplicateHead)
        #expect(advancedHead)
        #expect(firstTail)
        #expect(!duplicateTail)
        #expect(advancedTail)
    }

    @Test("a completed edge can request the same boundary again after paging restarts")
    func resetAfterCompletion() {
        var gate = ConversationPrefetchGate<Int>()
        let first = gate.shouldLoadBefore(hasMore: true, distance: 0, firstID: 10)
        _ = gate.shouldLoadBefore(hasMore: false, distance: 0, firstID: 10)
        let restarted = gate.shouldLoadBefore(hasMore: true, distance: 0, firstID: 10)
        #expect(first)
        #expect(restarted)
    }
}

@Suite("Conversation transcript append accounting")
struct ConversationAppendDeltaTests {
    @Test("true appends count only the new suffix")
    func trueAppend() {
        #expect(ConversationAppendDelta.count(previous: ["a", "b"], current: ["a", "b", "c", "d"]) == 2)
    }

    @Test("stream completion replaces the old tail without creating unread rows")
    func streamingCommit() {
        #expect(ConversationAppendDelta.count(previous: ["message", "stream"], current: ["message", "committed"]) == 0)
    }

    @Test("ticket echo replaces the old tail without creating unread rows")
    func ticketEcho() {
        #expect(ConversationAppendDelta.count(previous: ["message", "ticket"], current: ["message", "echo"]) == 0)
    }

    @Test("disjoint windows do not manufacture unread counts")
    func disjointWindows() {
        #expect(ConversationAppendDelta.count(previous: [1, 2], current: [100, 101]) == 0)
    }
}

@Suite("Conversation transcript tail geometry")
struct ConversationTailGeometryTests {
    @Test("tail pin reconverges after estimated wrapped rows resolve")
    func estimatedHeightResolution() {
        let estimatedOffset = ConversationTailGeometry.maximumOffset(
            contentHeight: 20_000,
            viewportHeight: 800,
            topInset: 44,
            bottomInset: 96
        )
        #expect(estimatedOffset == 19_296)

        let resolvedOffset = ConversationTailGeometry.maximumOffset(
            contentHeight: 60_000,
            viewportHeight: 800,
            topInset: 44,
            bottomInset: 96
        )
        #expect(ConversationTailGeometry.distance(
            contentOffset: resolvedOffset,
            contentHeight: 60_000,
            viewportHeight: 800,
            topInset: 44,
            bottomInset: 96
        ) == 0)
    }
}
