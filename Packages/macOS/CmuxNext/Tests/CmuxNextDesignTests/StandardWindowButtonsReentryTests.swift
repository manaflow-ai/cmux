import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// #38147 review P2 2: `ShellWindow.standardWindowButton` keeps AppKit's answer in a value it mutates. If an AppKit
/// getter read for that answer (style mask, `representedURL`, frame view) asks the window for a button again while the
/// value is being changed, Swift's exclusivity check stops the app (also in Release). The window reads everything the
/// answer needs before it changes the value. Own suite: on the base the re-entry stops the test process.
@MainActor @Suite(.serialized, .closesItsWindows) struct StandardWindowButtonsReentryTests {
    /// The same override as `ShellWindow`, with a `representedURL` getter that asks for a button once while armed.
    private final class ReenteringWindow: NSWindow {
        var armed = false
        var reentered = 0
        private var buttons = StandardWindowButtons()
        override var representedURL: URL? {
            get {
                if armed {
                    armed = false
                    reentered += 1
                    _ = standardWindowButton(.closeButton)
                }
                return super.representedURL
            }
            set { super.representedURL = newValue }
        }

        override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? {
            if case .known(let button) = buttons.answer(b, in: self) { return button }
            let button = super.standardWindowButton(b)
            armed = b == .documentIconButton
            let found = StandardWindowButtons.Found(button, for: b, in: self)
            armed = false
            buttons.store(found)
            return button
        }
    }

    @Test func aButtonAskedForWhileTheAnswerIsKeptDoesNotStopTheApp() {
        let w = ReenteringWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        #expect(w.standardWindowButton(.documentIconButton) == nil)
        #expect(w.reentered == 1, "the seam did not ask again while the answer was kept")
        #expect(w.standardWindowButton(.closeButton) != nil)
    }
}
