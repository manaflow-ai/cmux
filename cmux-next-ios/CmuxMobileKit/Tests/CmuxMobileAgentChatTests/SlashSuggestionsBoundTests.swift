import SwiftUI
import Testing
@testable import CmuxMobileAgentChat
#if os(iOS)
import UIKit
#endif

/// The slash-command list's height bound (`SlashSuggestionsBound`) and the layout that
/// applies it to the list's scroll view (`CappedHeightLayout`).
@MainActor
@Suite struct SlashSuggestionsBoundTests {
    @Test func takesTheRoomBetweenTheCeilingAndTheCard() {
        #expect(SlashSuggestionsBound(ceiling: 120, bottom: 420).maxHeight == 300)
    }

    @Test func neverLessThanOneRow() {
        // Landscape with the keyboard up: less room than a row.
        #expect(SlashSuggestionsBound(ceiling: 120, bottom: 140).maxHeight == SlashSuggestionsBound.minRowHeight)
        #expect(SlashSuggestionsBound(ceiling: 400, bottom: 300).maxHeight == SlashSuggestionsBound.minRowHeight)
    }

    @Test func unknownRoomFallsBackToFiveAndAHalfRows() {
        #expect(SlashSuggestionsBound(ceiling: nil, bottom: 400).maxHeight == SlashSuggestionsBound.minRowHeight * 5.5)
        #expect(SlashSuggestionsBound(ceiling: 100, bottom: nil).maxHeight == SlashSuggestionsBound.fallbackHeight)
    }

    #if os(iOS)
    /// A scroll view of `rows` 44 pt rows in the capped layout, measured at a phone's width
    /// with no height limit (as the chat's dock measures its stack).
    private func listHeight(rows: Int, cap: CGFloat) -> CGFloat {
        let list = CappedHeightLayout(maxHeight: cap) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        Text("/command\(row)").frame(maxWidth: .infinity, minHeight: SlashSuggestionsBound.minRowHeight)
                    }
                }
            }
        }
        let host = UIHostingController(rootView: list)
        return host.sizeThatFits(in: CGSize(width: 375, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @Test func aShortListIsAsTallAsItsRows() {
        #expect(abs(listHeight(rows: 2, cap: 300) - 2 * SlashSuggestionsBound.minRowHeight) < 0.5)
    }

    @Test func aLongListStopsAtTheCap() {
        #expect(abs(listHeight(rows: 20, cap: 300) - 300) < 0.5)
    }
    #endif
}
