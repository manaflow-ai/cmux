import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// CLOSE PERF (xctrace, 10 pane closes, 2026-11-08): AppKit rebuilds the titlebar's structural regions on every
/// motion frame and asks the window for each standard button. The cache kept only the buttons that exist, so a type
/// the window does not have (the document icon, the toolbar button) went to AppKit's whole-tree
/// `_NSViewStandardButtonSearch` every time: 6.9 ms of main-thread time per close. An absent button is an answer too.
@MainActor @Suite(.serialized, .closesItsWindows) struct StandardWindowButtonsAbsentTests {
    private final class CountingWindow: NSWindow {
        var searches = 0
        private var buttons = StandardWindowButtons()
        override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
            if case .known(let button) = buttons.answer(b, in: self) { return button }
            searches += 1
            let button = super.standardWindowButton(b)
            buttons.store(button, for: b, in: self)
            return button
        }
    }

    private func window() -> CountingWindow {
        let w = CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    @Test func anAbsentButtonIsSearchedOnce() {
        let w = window()
        defer { w.close() }
        #expect(w.standardWindowButton(.documentIconButton) == nil)
        for _ in 0..<10 { _ = w.standardWindowButton(.documentIconButton) }
        #expect(w.searches == 1, "an absent button was searched \(w.searches) times")
    }

    @Test func aPresentButtonIsSearchedOnce() {
        let w = window()
        defer { w.close() }
        let close = w.standardWindowButton(.closeButton)
        #expect(close != nil)
        for _ in 0..<10 { #expect(w.standardWindowButton(.closeButton) === close) }
        #expect(w.searches == 1)
    }

    @Test func aStyleChangeAsksAgain() {
        let w = window()
        defer { w.close() }
        _ = w.standardWindowButton(.documentIconButton)
        w.styleMask.remove(.miniaturizable)
        _ = w.standardWindowButton(.documentIconButton)
        #expect(w.searches == 2, "a style change kept the old absent answer")
    }

    @Test func aRepresentedURLAsksAgain() {
        let w = window()
        defer { w.close() }
        _ = w.standardWindowButton(.documentIconButton)
        w.representedURL = URL(fileURLWithPath: NSTemporaryDirectory())
        _ = w.standardWindowButton(.documentIconButton)
        #expect(w.searches == 2, "a document window kept the old absent answer")
    }
}
