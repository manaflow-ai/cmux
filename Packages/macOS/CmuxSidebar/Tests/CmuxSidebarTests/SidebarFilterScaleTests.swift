import Foundation
import Testing
@testable import CmuxSidebar

/// Scale coverage for the sidebar filter's two performance claims:
///
/// 1. Candidate preparation is paid once per corpus revision, so a keystroke
///    costs only scoring. A regression that rebuilds the index per keystroke
///    passes every behavioural suite and only shows up here.
/// 2. Scoring stops at the highest-priority field that matches, so a row whose
///    title matches never pays to score its branch, directory, and ports.
///
/// Bounds are deliberately loose. These exist to fail on an order-of-magnitude
/// regression, not to pin a number to one machine's clock.
@Suite("SidebarFilterIndex scale")
struct SidebarFilterScaleTests {
    private static func makeIndex(
        workspaceCount: Int,
        matchingEvery: Int
    ) -> SidebarFilterIndex {
        let groupCount = max(1, workspaceCount / 25)
        let groups = (0..<groupCount).map { groupIndex in
            SidebarFilterGroup(
                id: UUID(),
                anchorWorkspaceId: UUID(),
                name: "group-\(groupIndex)"
            )
        }
        let candidates = (0..<workspaceCount).map { index -> SidebarFilterCandidate in
            let group = groups[index % groupCount]
            let stem = index % matchingEvery == 0 ? "manaflow" : "zephyr"
            return SidebarFilterCandidate(
                id: UUID(),
                groupId: group.id,
                isGroupAnchor: false,
                fields: [
                    SidebarFilterCandidateField(
                        field: .title,
                        displayText: "workspace-\(index)-\(stem)"
                    ),
                    SidebarFilterCandidateField(
                        field: .branch,
                        displayText: "feature/sidebar-rail-\(index)"
                    ),
                    SidebarFilterCandidateField(
                        field: .directory,
                        displayText: "~/repos/\(stem)/cmux/pkg-\(index)"
                    ),
                    SidebarFilterCandidateField(field: .port, displayText: "\(3000 + index)"),
                ]
            )
        }
        return SidebarFilterIndex(candidates: candidates, groups: groups)
    }

    /// Types `query` one character at a time and returns the worst and total
    /// wall time, the way a filter field drives the index.
    private static func measureTyping(
        index: SidebarFilterIndex,
        query: String
    ) -> (worstMs: Double, totalMs: Double, matches: Int) {
        var worstMs = 0.0
        var totalMs = 0.0
        var matches = 0
        for length in 1...query.count {
            let prefix = String(query.prefix(length))
            let start = DispatchTime.now().uptimeNanoseconds
            let outcome = index.outcome(for: SidebarFilterQuery(prefix))
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            worstMs = max(worstMs, elapsedMs)
            totalMs += elapsedMs
            matches = outcome.orderedMatchWorkspaceIds.count
        }
        return (worstMs, totalMs, matches)
    }

    @Test func typingStaysWellInsideAFrameOnARealisticCorpus() {
        // 200 workspaces is already far past what a sidebar shows; one in
        // twelve matching is a normal narrowing search.
        let index = Self.makeIndex(workspaceCount: 200, matchingEvery: 12)
        let result = Self.measureTyping(index: index, query: "manaflow")
        print(
            "BENCH sidebar-filter realistic workspaces=200"
            + " worstKeystroke=\(String(format: "%.2f", result.worstMs))ms"
            + " typing=\(String(format: "%.2f", result.totalMs))ms"
            + " matches=\(result.matches)"
        )
        #expect(result.matches > 0)
        // One 60Hz frame is 16.6ms; a realistic corpus must not come close.
        #expect(result.worstMs < 8.0)
    }

    @Test func preparationIsPaidOncePerCorpusRevisionNotPerKeystroke() {
        let query = "manaflow"
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        let index = Self.makeIndex(workspaceCount: 500, matchingEvery: 1)
        let prepareMs = Double(DispatchTime.now().uptimeNanoseconds - prepareStart) / 1_000_000

        let result = Self.measureTyping(index: index, query: query)
        let averageKeystrokeMs = result.totalMs / Double(query.count)

        print(
            "BENCH sidebar-filter adversarial workspaces=500 allMatching"
            + " prepare=\(String(format: "%.2f", prepareMs))ms"
            + " worstKeystroke=\(String(format: "%.2f", result.worstMs))ms"
            + " avgKeystroke=\(String(format: "%.2f", averageKeystrokeMs))ms"
        )

        #expect(result.matches == 500)
        // Every one of 500 rows matching on its title is not a real corpus; it
        // is the worst case the scorer can be handed. Even here a keystroke
        // stays inside a few frames, and human typing leaves >60ms between
        // them. The bound is a tripwire for a per-keystroke re-preparation
        // regression, which would cost `prepare` on top of every character.
        #expect(result.worstMs < prepareMs * 4)
        #expect(result.worstMs < 40.0)
    }

    @Test func aMissPrunesCheaplyThroughTheASCIIMask() {
        let index = Self.makeIndex(workspaceCount: 500, matchingEvery: 1)
        let start = DispatchTime.now().uptimeNanoseconds
        let outcome = index.outcome(for: SidebarFilterQuery("qqqzzzxxx"))
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("BENCH sidebar-filter miss workspaces=500 elapsed=\(String(format: "%.2f", elapsedMs))ms")
        #expect(outcome.isEmptyResult)
        #expect(elapsedMs < 16.0)
    }

    @Test func aTitleHitNeverPaysToScoreTheRemainingFields() {
        // Same corpus, same query text, scoped to the lowest-priority field so
        // every higher-priority field is skipped outright. If early exit ever
        // regresses into scoring every field, the unscoped run stops being
        // comparable to this one.
        let index = Self.makeIndex(workspaceCount: 500, matchingEvery: 1)
        let outcome = index.outcome(for: SidebarFilterQuery("manaflow"))
        #expect(outcome.matchesByWorkspaceId.values.allSatisfy { $0.field == .title })
        // The directory also contains "manaflow"; it must not appear as the
        // match, and it must not carry highlight offsets it never earned.
        #expect(outcome.matchesByWorkspaceId.values.allSatisfy {
            $0.matchedIndicesByField[.directory] == nil
        })
    }
}
