import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Crash duplicate window matcher")
struct CrashWindowSignatureTests {
    private typealias Signature = CrashWindowSignature

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
        #expect(lhs.isCrashDuplicate(of: lhs))
    }

    @Test("Legacy windows without IDs and the same checkpoints are one window")
    func legacyIdenticalCheckpoints() {
        let lhs = signature(windowId: nil, workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: nil, workspaces: 4, checkpoints: ["b", "a"], titles: titles.reversed())
        #expect(lhs.isCrashDuplicate(of: rhs))
    }

    @Test("A later generation of the same window with one new checkpoint is one window")
    func sameWindowFuzzyGeneration() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "e"], titles: titles.reversed())
        #expect(lhs.isCrashDuplicate(of: rhs))
    }

    // Seen on m3, 2026-10-20: two windows with different IDs, the same 41
    // titled workspaces, and every one of the first window's 44 agent
    // checkpoints also in the second's 86. One agent session lives in one
    // place, so this is the same window replayed after a crash.
    @Test("A replayed window with a new ID whose checkpoints are all in the other is one window")
    func replayedWindowWithNewID() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles.reversed())
        #expect(lhs.isCrashDuplicate(of: rhs))
        #expect(rhs.isCrashDuplicate(of: lhs))
    }

    @Test("Different window IDs with equal checkpoint sets are one window")
    func differentIDsEqualCheckpoints() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["c", "b", "a"], titles: titles.reversed())
        #expect(lhs.isCrashDuplicate(of: rhs))
        #expect(rhs.isCrashDuplicate(of: lhs))
    }

    @Test("Different window IDs need every checkpoint of the smaller window, not most")
    func differentIDsPartialOverlapStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c", "x"], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Different window IDs sharing a single checkpoint stay separate")
    func differentIDsSingleCheckpointStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Same titles but disjoint checkpoints are two windows")
    func sameTitlesDisjointCheckpointsStaySeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["x", "y"], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Overlap below 75 percent of the smaller window stays separate even with one ID")
    func sameWindowLowOverlapStaysSeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let rhs = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "x", "y"], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: rhs))
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
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("A different workspace count keeps windows separate")
    func differentWorkspaceCountStaysSeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: titles)
        let rhs = signature(windowId: UUID(), workspaces: 5, checkpoints: ["a", "b", "c"], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Untitled windows never merge on checkpoints alone across IDs")
    func untitledDifferentIDsStaySeparate() {
        let lhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b"], titles: [])
        let rhs = signature(windowId: UUID(), workspaces: 4, checkpoints: ["a", "b", "c"], titles: [])
        #expect(!lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Titles may be missing from at most two workspaces")
    func titleThresholdAllowsTwoUntitledWorkspaces() {
        let six = ["a", "b", "c", "d"]
        // 6 workspaces, 4 titled: count - 2 titles, enough.
        let lhs = signature(windowId: UUID(), workspaces: 6, checkpoints: ["x", "y"], titles: six)
        let rhs = signature(windowId: UUID(), workspaces: 6, checkpoints: ["x", "y", "z"], titles: six)
        #expect(lhs.isCrashDuplicate(of: rhs))
        // 6 workspaces, 3 titled: count - 3 titles, not enough.
        let fewer = Array(six.prefix(3))
        let lhsFew = signature(windowId: UUID(), workspaces: 6, checkpoints: ["x", "y"], titles: fewer)
        let rhsFew = signature(windowId: UUID(), workspaces: 6, checkpoints: ["x", "y", "z"], titles: fewer)
        #expect(!lhsFew.isCrashDuplicate(of: rhsFew))
    }

    @Test("A small window needs three titles, not two")
    func smallWindowNeedsThreeTitles() {
        let three = signature(windowId: UUID(), workspaces: 3, checkpoints: ["x", "y"], titles: ["a", "b", "c"])
        let threeReplay = signature(windowId: UUID(), workspaces: 3, checkpoints: ["x", "y", "z"], titles: ["c", "b", "a"])
        #expect(three.isCrashDuplicate(of: threeReplay))
        let two = signature(windowId: UUID(), workspaces: 2, checkpoints: ["x", "y"], titles: ["a", "b"])
        let twoReplay = signature(windowId: UUID(), workspaces: 2, checkpoints: ["x", "y", "z"], titles: ["b", "a"])
        #expect(!two.isCrashDuplicate(of: twoReplay))
    }

    @Test("Exactly 75 percent overlap of the smaller window merges; just under does not")
    func fuzzyOverlapBoundary() {
        let id = UUID()
        let atBoundary = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "d"], titles: titles)
        let threeOfFour = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c", "x"], titles: titles)
        #expect(atBoundary.isCrashDuplicate(of: threeOfFour))
        let twoOfThree = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "x"], titles: titles)
        let three = signature(windowId: id, workspaces: 4, checkpoints: ["a", "b", "c"], titles: titles)
        #expect(!twoOfThree.isCrashDuplicate(of: three))
    }

    @Test("The same window ID with the same workspace IDs is one window, checkpoints or not")
    func sameWorkspaceIDsWithoutCheckpoints() {
        let id = UUID()
        let workspaceIDs = [UUID(), UUID()]
        let lhs = signature(windowId: id, workspaces: 2, checkpoints: [], titles: [], workspaceIDs: workspaceIDs)
        let rhs = signature(windowId: id, workspaces: 2, checkpoints: [], titles: [], workspaceIDs: workspaceIDs)
        #expect(lhs.isCrashDuplicate(of: rhs))
    }

    @Test("Windows with neither checkpoints nor workspace IDs never merge")
    func noEvidenceStaysSeparate() {
        let id = UUID()
        let lhs = signature(windowId: id, workspaces: 4, checkpoints: [], titles: titles)
        #expect(!lhs.isCrashDuplicate(of: lhs))
    }
}
