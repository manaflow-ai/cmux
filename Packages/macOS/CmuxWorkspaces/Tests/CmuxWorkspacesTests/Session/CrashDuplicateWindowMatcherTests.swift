import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Crash duplicate window matcher")
struct CrashDuplicateWindowMatcherTests {
    private typealias Signature = CrashDuplicateWindowMatcher.WindowSignature

    private func signature(
        windowId: UUID?,
        workspaces: Int,
        checkpoints: [String],
        titles: [String],
        workspaceIDs: [UUID]? = nil
    ) -> Signature {
        Signature(
            windowId: windowId,
            workspaceCount: workspaces,
            workspaceIDs: workspaceIDs,
            checkpointIDs: Set(checkpoints),
            workspaceTitles: titles
        )
    }

    private let titles = ["api", "docs", "infra", "web"]

    @Test("The same window ID with the same checkpoints is one window")
    func sameWindowIdenticalCheckpoints() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c"], titles: titles)
        #expect(CrashDuplicateWindowMatcher.isDuplicate(lhs, lhs))
    }

    @Test("Legacy windows without IDs and the same checkpoints are one window")
    func legacyIdenticalCheckpoints() {
        let lhs = signature(windowId: nil, workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: nil, workspaces: 4, checkpoints: ["b", "a"], titles: titles.reversed())
        #expect(CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("A later generation of the same window with one new checkpoint is one window")
    func sameWindowFuzzyGeneration() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "e"], titles: titles.reversed())
        #expect(CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    // Seen on m3, 2026-10-20: two windows with different IDs, the same 41
    // titled workspaces, and every one of the first window's 44 agent
    // checkpoints also in the second's 86. One agent session lives in one
    // place, so this is the same window replayed after a crash.
    @Test("A replayed window with a new ID whose checkpoints are all in the other is one window")
    func replayedWindowWithNewID() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles.reversed())
        #expect(CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
        #expect(CrashDuplicateWindowMatcher.isDuplicate(rhs, lhs))
    }

    @Test("Different window IDs need every checkpoint of the smaller window, not most")
    func differentIDsPartialOverlapStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "x"], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("Different window IDs sharing a single checkpoint stay separate")
    func differentIDsSingleCheckpointStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("Same titles but disjoint checkpoints are two windows")
    func sameTitlesDisjointCheckpointsStaySeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["x", "y"], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("Overlap below 75 percent of the smaller window stays separate even with one ID")
    func sameWindowLowOverlapStaysSeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "x", "y"], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("A different title multiset keeps windows separate")
    func differentTitlesStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(
            windowId: UUID(),
            workspaces: 4,
            checkpoints: ["a", "b", "c"],
            titles: ["api", "docs", "infra", "mobile"]
        )
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("A different workspace count keeps windows separate")
    func differentWorkspaceCountStaysSeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 5, checkpoints: ["a", "b", "c"], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("Untitled windows never merge on checkpoints alone across IDs")
    func untitledDifferentIDsStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: [])
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c"], titles: [])
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("The same window ID with the same workspace IDs is one window, checkpoints or not")
    func sameWorkspaceIDsWithoutCheckpoints() {
        let id = UUID()
        let workspaceIDs = [UUID(), UUID()]
        let lhs = signature(windowId: id, workspaces: 2, checkpoints: [], titles: [], workspaceIDs: workspaceIDs)
        let rhs = signature(windowId: id, workspaces: 2, checkpoints: [], titles: [], workspaceIDs: workspaceIDs)
        #expect(CrashDuplicateWindowMatcher.isDuplicate(lhs, rhs))
    }

    @Test("Windows with neither checkpoints nor workspace IDs never merge")
    func noEvidenceStaysSeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: [], titles: titles)
        #expect(!CrashDuplicateWindowMatcher.isDuplicate(lhs, lhs))
    }
}
