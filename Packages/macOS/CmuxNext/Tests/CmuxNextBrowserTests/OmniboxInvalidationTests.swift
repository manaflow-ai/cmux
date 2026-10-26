import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// Chrome-parity p03-rendering-065 (MQ-damage-owners, CmuxNextBrowser): each typed character shows
/// the suggestion card again. The rows that keep their match lay out and paint nothing: the card
/// roots its theme scope once (rooting repaints every view under it), and its frame, corner and the
/// rows' insets ask for layout only when they move. The omnibar's badges repaint only for a new
/// badge. Chromium's `OmniboxResultView::SetMatch` updates a row in place and invalidates only what
/// the new match changed (chrome/browser/ui/views/omnibox/omnibox_result_view.cc).
@MainActor @Suite(.serialized)
struct OmniboxInvalidationTests {
    @Test func retypingLeavesTheRowsThatKeptTheirMatchClean() throws {
        _ = NSApplication.shared
        let bar = AddressBarView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        defer {
            bar.panel.dismiss()
            window.close()
        }
        bar.frame = NSRect(x: 10, y: 340, width: 600, height: 34)
        let pane = try #require(window.contentView)
        pane.addSubview(bar)
        let url = try #require(URL(string: "https://example.com/"))
        func suggestions(_ typed: String) -> [BrowserSuggestion] {
            [BrowserSuggestion(kind: .search, title: typed, detail: "", url: url, score: 1)]
                + (1..<5).map { BrowserSuggestion(kind: .search, title: "query \($0)", detail: "", url: url, score: 1) }
        }
        bar.panel.show(suggestions("q"), highlighted: 0, at: bar, pane: pane, in: window)
        let card = bar.panel.cardView
        card.layoutSubtreeIfNeeded()
        card.displayIfNeeded()
        let kept = Array(bar.panel.rowViews.dropFirst())
        try #require(kept.count == 4)
        for row in bar.panel.rowViews { row.needsDisplay = false }

        bar.panel.show(suggestions("qu"), highlighted: 0, at: bar, pane: pane, in: window)
        #expect(!card.needsLayout, "the card did not move")
        for (index, row) in kept.enumerated() {
            #expect(!row.needsLayout, "row \(index + 1) kept its match and laid out")
            #expect(!row.needsDisplay, "row \(index + 1) kept its match and repainted")
        }
    }

    @Test func theSameProfileBadgePaintsNothing() {
        let badge = ProfileBadgeView(frame: .zero)
        let work = BrowserProfileBadge(monogram: "W", color: .blue, name: "Work")
        badge.show(work)
        badge.needsDisplay = false
        badge.show(work)
        #expect(!badge.needsDisplay)
        badge.show(BrowserProfileBadge(monogram: "P", color: .green, name: "Personal"))
        #expect(badge.needsDisplay)
    }

    @Test func theSameFocusModeTextPaintsNothing() {
        let badge = FocusModeBadgeView(frame: .zero)
        badge.needsDisplay = false
        badge.show(armed: false)
        #expect(!badge.needsDisplay, "the text it shows already")
        let before = badge.shownText
        badge.show(armed: true)
        #expect(badge.shownText != before)
        #expect(!badge.needsDisplay, "its colors do not follow the text")
    }
}
