import AppKit
@testable import CmuxNextPalette
import Testing

/// A detached palette panel can become key after its content is attached. The query field must
/// remain the panel's initial responder so AppKit gives it the keyboard during that handoff.
@MainActor
struct PaletteFocusTests {
    @Test func queryFieldRegistersAsThePanelInitialResponder() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content
        let bar = PaletteSearchBar(frame: content.bounds)
        let replacement = PaletteSearchBar(frame: content.bounds)
        content.addSubview(bar)
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)

        #expect(window.initialFirstResponder === bar.field)
        content.addSubview(replacement)
        #expect(window.initialFirstResponder === replacement.field)
        bar.removeFromSuperview()
        #expect(window.initialFirstResponder === replacement.field)
        replacement.removeFromSuperview()
        #expect(window.initialFirstResponder == nil)
    }
}
