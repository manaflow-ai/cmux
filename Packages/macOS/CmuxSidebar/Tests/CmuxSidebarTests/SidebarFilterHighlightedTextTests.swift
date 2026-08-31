import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarFilterHighlightedText")
struct SidebarFilterHighlightedTextTests {
    private func concatenated(_ runs: [SidebarFilterHighlightedText.Run]) -> String {
        runs.map(\.text).joined()
    }

    @Test func noRangesYieldOneUnmatchedRun() {
        let runs = SidebarFilterHighlightedText.runs(displayText: "cmux-web", ranges: [])
        #expect(runs == [.init(text: "cmux-web", isMatch: false)])
    }

    @Test func emptyTextYieldsNoRuns() {
        #expect(SidebarFilterHighlightedText.runs(displayText: "", ranges: []).isEmpty)
    }

    @Test func aLeadingMatchSplitsIntoTwoRuns() {
        let runs = SidebarFilterHighlightedText.runs(displayText: "cmux-web", ranges: [0..<4])
        #expect(runs == [
            .init(text: "cmux", isMatch: true),
            .init(text: "-web", isMatch: false),
        ])
    }

    @Test func anInteriorMatchSplitsIntoThreeRuns() {
        let runs = SidebarFilterHighlightedText.runs(displayText: "cmux-web", ranges: [5..<8])
        #expect(runs == [
            .init(text: "cmux-", isMatch: false),
            .init(text: "web", isMatch: true),
        ])
    }

    @Test func severalRangesAlternate() {
        let runs = SidebarFilterHighlightedText.runs(
            displayText: "sidebar-rail",
            ranges: [0..<2, 8..<12]
        )
        #expect(runs.map(\.isMatch) == [true, false, true])
        #expect(concatenated(runs) == "sidebar-rail")
    }

    @Test func runsAlwaysReproduceTheOriginalLabel() {
        // The label the user reads must never change because of highlighting.
        let text = "feature/sidebar-rail-42"
        for ranges in [[0..<7], [8..<15], [0..<1, 4..<6, 20..<23]] {
            let runs = SidebarFilterHighlightedText.runs(displayText: text, ranges: ranges)
            #expect(concatenated(runs) == text)
        }
    }

    @Test func outOfBoundsRangesFallBackToAPlainLabel() {
        let runs = SidebarFilterHighlightedText.runs(displayText: "cmux", ranges: [0..<99])
        #expect(runs == [.init(text: "cmux", isMatch: false)])
    }

    @Test func overlappingRangesAreSkippedRatherThanDuplicatingCharacters() {
        let runs = SidebarFilterHighlightedText.runs(
            displayText: "cmux-web",
            ranges: [0..<4, 2..<6]
        )
        #expect(concatenated(runs) == "cmux-web")
    }

    @Test func aFullyMatchedLabelIsOneMatchedRun() {
        let runs = SidebarFilterHighlightedText.runs(displayText: "cmux", ranges: [0..<4])
        #expect(runs == [.init(text: "cmux", isMatch: true)])
    }
}
