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

    /// A character typed on the TextBox's line lays the terminal out not at all; a new line does.
    @Test func typingInTheTextBoxLaysOutTheHostOnlyForANewLine() {
        let container = NSView()
        let window = window(with: container, size: NSSize(width: 600, height: 400))
        defer { window.close() }
        let model = TextBoxModel()
        model.isVisible = true
        let box = TextBoxView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        container.addSubview(box)
        box.frame = NSRect(x: 0, y: 0, width: 600, height: 36)
        func type(_ text: String) {
            box.textView.string = text
            box.textDidChange(Notification(name: NSText.didChangeNotification, object: box.textView))
        }
        type("m")
        container.layoutSubtreeIfNeeded()
        for text in ["ma", "mak", "make"] {
            type(text)
            #expect(!container.needsLayout, "typing \(text) laid the terminal out")
        }
        type("make\ntest")
        #expect(container.needsLayout, "a second line grows the strip")
    }
}
