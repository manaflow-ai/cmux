import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// Chrome-parity p03-rendering-065 (MQ-damage-owners, CmuxNextTerminal): the terminal host and its
/// TextBox strip lay out only when a value they place changed. Every tab switch hands the host its
/// Restart action again, and each character typed in the TextBox reported a new height to the host;
/// neither moves anything unless a button shows or goes or the strip gains or loses a line.
/// Chromium invalidates layout for the properties that changed (third_party/blink/renderer/core/
/// layout/layout_object.cc `SetNeedsLayout` from a style difference, never from a re-applied value).
@MainActor @Suite(.serialized)
struct TerminalInvalidationTests {
    private func window(with view: NSView, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// A tab switch sets the same Restart action again: no layout while the button neither shows nor goes.
    @Test func reofferingRestartLaysOutOnlyWhenTheButtonChanges() {
        let host = TerminalHostView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = window(with: host, size: NSSize(width: 800, height: 600))
        defer { window.close() }
        host.onRestart = {}
        #expect(!host.needsLayout, "a live shell shows no Restart: nothing moved")
        host.onRestart = nil
        host.showStatus(.exited)
        host.layoutSubtreeIfNeeded()
        #expect(!host.offersRestart, "no action: no button")
        host.onRestart = {}
        #expect(host.offersRestart)
        #expect(host.needsLayout, "Restart shows: the overlays move")
        host.layoutSubtreeIfNeeded()
        host.onRestart = {}
        #expect(!host.needsLayout, "the same offer again laid the host out")
        host.onRestart = nil
        #expect(host.needsLayout, "Restart goes")
    }

    /// A host with a shown TextBox strip as its bottom accessory, laid out in a window.
    private func hostWithTextBox(size: NSSize) -> (host: TerminalHostView, box: TextBoxView, window: NSWindow) {
        let host = TerminalHostView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let model = TextBoxModel()
        model.isVisible = true
        let box = TextBoxView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        host.bottomAccessory = box
        let window = window(with: host, size: size)
        settle(host)
        return (host, box, window)
    }

    /// Lays the host out until nothing under it asks again (a strip that rewraps asks the host once more).
    private func settle(_ host: TerminalHostView) {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
    }

    private func type(_ text: String, in box: TextBoxView) {
        box.textView.string = text
        box.textDidChange(Notification(name: NSText.didChangeNotification, object: box.textView))
    }

    /// A character typed on the TextBox's line lays the terminal out not at all; a new line does.
    @Test func typingInTheTextBoxLaysOutTheHostOnlyForANewLine() throws {
        let (host, box, window) = hostWithTextBox(size: NSSize(width: 600, height: 400))
        defer { window.close() }
        type("m", in: box)
        settle(host)
        try #require(!host.needsLayout && box.frame.height == ceil(box.fittingSize.height), "the host framed the strip at its fitting height")
        for text in ["ma", "mak", "make"] {
            type(text, in: box)
            #expect(!host.needsLayout, "typing \(text) laid the terminal out")
        }
        type("make\ntest", in: box)
        #expect(host.needsLayout, "a second line grows the strip")
    }

    /// The host frames the strip again without a typed character (a narrower pane wraps its text):
    /// typing back to the old height compares with the height the host gave, not one the strip
    /// reported earlier, so the strip shrinks and the terminal takes its room back.
    @Test func typingBackToAnEarlierHeightAfterAResizeLaysOutTheHost() throws {
        let (host, box, window) = hostWithTextBox(size: NSSize(width: 800, height: 600))
        defer { window.close() }
        type(String(repeating: "make test ", count: 5), in: box) // one line at 800 pt, more at 300 pt
        settle(host)
        let oneLine = box.frame.height
        try #require(oneLine == ceil(box.fittingSize.height))
        host.setFrameSize(NSSize(width: 300, height: 600))
        host.needsLayout = true // an unrelated host layout after the resize (the pane's own)
        settle(host)
        try #require(box.frame.height > oneLine, "the narrower strip wraps its text into more lines")
        type("make", in: box)
        #expect(host.needsLayout, "one line again: the host must frame the strip at one line")
        settle(host)
        #expect(box.frame.height == oneLine, "the strip kept the wrapped height for one line of text")
    }

    /// A narrower strip rewraps its text into more lines: it asks the host to frame it taller itself.
    @Test func aResizeThatRewrapsTheTextBoxGrowsTheStrip() {
        let (host, box, window) = hostWithTextBox(size: NSSize(width: 800, height: 600))
        defer { window.close() }
        type(String(repeating: "make test ", count: 5), in: box)
        settle(host)
        let oneLine = box.frame.height
        host.setFrameSize(NSSize(width: 300, height: 600))
        settle(host)
        #expect(box.frame.height > oneLine, "the strip kept one line's height for wrapped text")
        #expect(box.frame.height == ceil(box.fittingSize.height))
    }
}
