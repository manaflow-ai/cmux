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
            let found = StandardWindowButtons.Found(button, for: b, in: self)
            buttons.store(found)
            return button
        }
    }

    private func window() -> CountingWindow {
        let w = CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    // AppKit asks the window for its buttons itself (window set-up, titlebar rebuilds), so each test counts the
    // searches after its own first lookup, not from zero.

    @Test func anAbsentButtonIsNotSearchedAgain() {
        let w = window()
        defer { w.close() }
        #expect(w.standardWindowButton(.documentIconButton) == nil)
        let first = w.searches
        for _ in 0..<10 { _ = w.standardWindowButton(.documentIconButton) }
        #expect(w.searches == first, "an absent button was searched \(w.searches - first) more times")
    }

    @Test func aPresentButtonIsNotSearchedAgain() {
        let w = window()
        defer { w.close() }
        let close = w.standardWindowButton(.closeButton)
        #expect(close != nil)
        let first = w.searches
        for _ in 0..<10 { #expect(w.standardWindowButton(.closeButton) === close) }
        #expect(w.searches == first)
    }

    @Test func aStyleChangeAsksAgain() {
        var buttons = StandardWindowButtons()
        let w = window()
        defer { w.close() }
        buttons.store(.init(nil, for: .documentIconButton, in: w))
        guard case .known(nil) = buttons.answer(.documentIconButton, in: w) else {
            Issue.record("the absent answer was not kept")
            return
        }
        w.styleMask.remove(.miniaturizable)
        guard case .unknown = buttons.answer(.documentIconButton, in: w) else {
            Issue.record("a style change kept the old absent answer")
            return
        }
    }

    @Test func aRepresentedURLAsksAgain() {
        var buttons = StandardWindowButtons()
        let w = window()
        defer { w.close() }
        buttons.store(.init(nil, for: .documentIconButton, in: w))
        w.representedURL = URL(fileURLWithPath: NSTemporaryDirectory())
        guard case .unknown = buttons.answer(.documentIconButton, in: w) else {
            Issue.record("a document window kept the old absent answer")
            return
        }
    }

    @Test func aMissingTrafficLightIsNotKept() {
        var buttons = StandardWindowButtons()
        let w = window()
        defer { w.close() }
        buttons.store(.init(nil, for: .closeButton, in: w))
        guard case .unknown = buttons.answer(.closeButton, in: w) else {
            Issue.record("a nil traffic light was kept; it can be one AppKit moved during a full-screen exit")
            return
        }
    }

    // #38147 review P2 1: AppKit can show the versions button when `isDocumentEdited` changes, with no change of style
    // or URL, so a document window keeps no absent document button at all.
    @Test func aDocumentWindowKeepsNoAbsentDocumentButton() {
        var buttons = StandardWindowButtons()
        let w = window()
        defer { w.close() }
        w.representedURL = URL(fileURLWithPath: NSTemporaryDirectory())
        buttons.store(.init(nil, for: .documentVersionsButton, in: w))
        guard case .unknown = buttons.answer(.documentVersionsButton, in: w) else {
            Issue.record("a document window kept an absent versions button")
            return
        }
    }

    // #38147 review P2 3: a window that gets a toolbar can have a toolbar button.
    @Test func aToolbarAsksAgain() {
        var buttons = StandardWindowButtons()
        let w = window()
        defer { w.close() }
        buttons.store(.init(nil, for: .toolbarButton, in: w))
        w.toolbar = NSToolbar(identifier: "swb-p2")
        guard case .unknown = buttons.answer(.toolbarButton, in: w) else {
            Issue.record("a window with a new toolbar kept the old absent toolbar button")
            return
        }
    }
}
