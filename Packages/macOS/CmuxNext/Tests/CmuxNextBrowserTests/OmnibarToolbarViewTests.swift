import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The omnibar row a surface that is not a browser page shows (the New Tab page, cx-e2aa): the
/// browser toolbar's omnibar at the toolbar's height and insets, and its suggestion card flush
/// under the bar inside the surface it sits on.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct OmnibarToolbarViewTests {
    @Test func theRowHasTheBrowserToolbarsHeightAndInsets() {
        let row = OmnibarToolbarView(suggestionEngine: OmniboxSuggestionEngine())
        row.frame = NSRect(x: 0, y: 0, width: 800, height: row.preferredHeight)
        row.layoutSubtreeIfNeeded()
        #expect(row.preferredHeight == OmnibarStyle.toolbarHeight(scale: NSScreen.main?.backingScaleFactor ?? 2))
        #expect(row.addressBar.superview === row)
        #expect(row.addressBar.frame.minX == OmnibarStyle.toolbarInset)
        #expect(row.addressBar.frame.width == 800 - 2 * OmnibarStyle.toolbarInset)
        #expect(row.addressBar.frame.height == OmnibarStyle.barHeight)
    }

    @Test func theSuggestionCardOpensFlushUnderTheBarInsideTheSurface() async throws {
        let store = InMemoryBrowserHistory()
        for _ in 0..<5 { store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: Date()) }
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 320))
        let row = OmnibarToolbarView(suggestionEngine: OmniboxSuggestionEngine(history: store))
        row.frame = NSRect(x: 0, y: 320 - row.preferredHeight, width: 900, height: row.preferredHeight)
        surface.addSubview(row)
        row.cardClip = surface
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        let bar = row.addressBar
        defer {
            bar.dismissRows()
            window.orderOut(nil)
        }
        await bar.suggestionEngine.historySettled()
        bar.debugType("git")
        // Bounded: the card shows once the history query answers (a stalled host fails, never hangs).
        for _ in 0..<500 where !bar.isShowingSuggestions { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bar.isShowingSuggestions)
        let reported = try #require(bar.debugCard)
        #expect(reported.paneLayer && reported.isFlushUnderBar)
        #expect(bar.cardClipView === surface)
    }
}
