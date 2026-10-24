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
        let bar = PaletteSearchBar(frame: window.contentView?.bounds ?? .zero)
        window.contentView = bar
        defer { window.orderOut(nil) }

        _ = window.makeFirstResponder(nil)

        #expect(window.initialFirstResponder === bar.field)
    }
}
