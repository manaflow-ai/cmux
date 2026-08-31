import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarFilterMatch highlighting")
struct SidebarFilterHighlightTests {
    private func match(indices: Set<Int>, field: SidebarFilterField = .title) -> SidebarFilterMatch {
        SidebarFilterMatch(
            workspaceId: UUID(),
            score: 1,
            field: field,
            matchedIndicesByField: [field: indices]
        )
    }

    @Test func adjacentOffsetsCollapseIntoOneRange() {
        let ranges = match(indices: [0, 1, 2]).highlightRanges(for: .title, in: "cmux-web")
        #expect(ranges == [0..<3])
    }

    @Test func gapsSplitIntoSeparateRanges() {
        let ranges = match(indices: [0, 1, 5, 6, 7]).highlightRanges(for: .title, in: "cmux-web")
        #expect(ranges == [0..<2, 5..<8])
    }

    @Test func singleOffsetsBecomeSingleCharacterRanges() {
        let ranges = match(indices: [0, 2, 4]).highlightRanges(for: .title, in: "cmux-web")
        #expect(ranges == [0..<1, 2..<3, 4..<5])
    }

    @Test func rangesAreAscendingRegardlessOfSetIteration() {
        // Set iteration order is unspecified; the ranges must not be.
        let ranges = match(indices: [7, 1, 4, 0, 5]).highlightRanges(for: .title, in: "cmux-web")
        #expect(ranges == [0..<2, 4..<6, 7..<8])
    }

    @Test func fieldWithoutMatchesHighlightsNothing() {
        let ranges = match(indices: [0, 1]).highlightRanges(for: .branch, in: "main")
        #expect(ranges.isEmpty)
    }

    @Test func offsetsPastTheDisplayStringHighlightNothing() {
        // Defence in depth against a stale match outliving a renamed row:
        // highlighting out of bounds would trap in the row's text layout.
        let ranges = match(indices: [0, 1, 99]).highlightRanges(for: .title, in: "cmux")
        #expect(ranges.isEmpty)
    }

    @Test func nonLengthPreservingNormalizationCarriesNoHighlights() {
        // Diacritic folding can change the character count, which invalidates
        // the offsets against the displayed string. The field still scores; it
        // just renders unhighlighted rather than underlining the wrong glyphs.
        let field = SidebarFilterCandidateField(field: .title, displayText: "café")
        if !field.isDisplayIndexAligned {
            let index = SidebarFilterIndex(
                candidates: [SidebarFilterCandidate(id: UUID(), fields: [field])],
                groups: []
            )
            let outcome = index.outcome(for: SidebarFilterQuery("cafe"))
            let match = outcome.matchesByWorkspaceId.values.first
            #expect(match != nil)
            #expect(match?.matchedIndicesByField.isEmpty == true)
        }
    }

    @Test func alignedAsciiFieldKeepsItsHighlights() {
        let id = UUID()
        let index = SidebarFilterIndex(
            candidates: [SidebarFilterCandidate(
                id: id,
                fields: [SidebarFilterCandidateField(field: .title, displayText: "cmux-web")]
            )],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("cmux"))
        let ranges = outcome.matchesByWorkspaceId[id]?
            .highlightRanges(for: .title, in: "cmux-web")
        #expect(ranges == [0..<4])
    }
}
