import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Foundation
import Testing

/// Lawrence 2026-11-23 (msg 48249): "find frame where i type option backspace, we need to fix that jank frame". In his
/// recording (CleanShot 2026-11-23 at 3.16.36 PM, frames 44 to 47, 1.328 to 1.417 s) Option-Backspace empties the
/// field to "Search or enter address" while the card still draws the old "dlksdjf" row: two frames at full strength,
/// then two fading. The card and the bar's card top faded out over `MotionFade.omniboxPopup` after the rows were gone
/// from the state (d8917c9f41c3, #44449). Chromium takes its popup off at once; so does the card now.
@MainActor
@Suite(.serialized)
struct OmnibarCardClosesAtOnceTests {
    private func bar() throws -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = OnScreenWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        bar.frame = NSRect(x: 10, y: 240, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/"), security: .secure)
        // On an awake screen, so the card's fades run as in the app: with no screen, or a display asleep (the fleet's
        // test hosts), Motion applies a fade at once and every close is instant whatever the code does.
        window.shownOn = try #require(NSScreen.main ?? NSScreen.screens.first, "SETUP: the host has no screen")
        window.orderFrontRegardless()
        return (bar, window)
    }

    /// Option-Backspace empties the field: the card with the old row and the bar's card top are gone in that same turn,
    /// with no fade that keeps the old row on screen under the empty field.
    @Test func optionBackspaceTakesTheCardOffAtOnce() throws {
        let (bar, window) = try bar()
        let savedSleep = DisplaySleep.asleepOverride
        DisplaySleep.asleepOverride = false
        defer {
            DisplaySleep.asleepOverride = savedSleep
            window.closeTestWindowAndOverlay()
        }
        try #require(Motion.canAnimate(in: bar), "SETUP: the window has no awake screen, so no fade could run")
        bar.focus()
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        editor.insertText("dlksdjf", replacementRange: NSRange(location: NSNotFound, length: 0))
        let row = BrowserSuggestion(kind: .search, title: "dlksdjf", detail: "", url: try #require(URL(string: "https://www.google.com/search?q=dlksdjf")),
                                    score: 1)
        bar.controller.send(.suggestions(generation: bar.controller.state.generation, rows: [row]))
        #expect(bar.state.isPopupOpen)
        #expect(bar.panel.cardView.window != nil, "the card is on screen with its row")
        #expect(bar.debugCardTopShown, "the bar's card top shows with the card")

        editor.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        #expect(editor.string.isEmpty, "Option-Backspace empties the field: \(editor.string.debugDescription)")
        #expect(!bar.state.isPopupOpen)
        #expect(bar.panel.cardView.window == nil, "the card with the old row stays on screen under the empty field")
        #expect(!bar.debugCardTopShown, "the bar's card top stays on screen with no card under it")
    }

    /// Escape, Enter and a lost focus close the card the same way: no close leaves old rows on screen.
    @Test func escapeTakesTheCardOffAtOnce() throws {
        let (bar, window) = try bar()
        let savedSleep = DisplaySleep.asleepOverride
        DisplaySleep.asleepOverride = false
        defer {
            DisplaySleep.asleepOverride = savedSleep
            window.closeTestWindowAndOverlay()
        }
        try #require(Motion.canAnimate(in: bar), "SETUP: the window has no awake screen, so no fade could run")
        bar.focus()
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        editor.insertText("swift", replacementRange: NSRange(location: NSNotFound, length: 0))
        let row = BrowserSuggestion(kind: .navigate, title: "swift.org", detail: "", url: try #require(URL(string: "https://swift.org/")), score: 1)
        bar.controller.send(.suggestions(generation: bar.controller.state.generation, rows: [row]))
        #expect(bar.panel.cardView.window != nil)
        bar.controller.send(.key(.escape))
        #expect(!bar.state.isPopupOpen)
        #expect(bar.panel.cardView.window == nil, "Escape leaves the card fading over the reverted field")
        #expect(!bar.debugCardTopShown)
    }
}

/// A window on `shownOn`, whatever screen WindowServer gave it (none on a host whose display is off).
private final class OnScreenWindow: NSWindow {
    var shownOn: NSScreen?
    override var screen: NSScreen? { shownOn ?? super.screen }
}

private extension NSWindow {
    /// Closes the fixture window and the overlay panel its `WindowOverlayHost` keeps (the card shows there).
    func closeTestWindowAndOverlay() {
        let panel = WindowOverlayHost.existingHost(for: self)?.panel
        isReleasedWhenClosed = false
        close()
        panel?.close()
    }
}
