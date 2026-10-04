import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The which-key overlay draws on the window's overlay host (above every
/// Chromium page window), not in a child panel of its own, and never takes
/// the mouse.
@MainActor
@Suite(.serialized) struct OverlayWhichKeyTests {
    @Test func whichKeyDrawsOnTheOverlayHost() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
            window.close()
        }
        let controller = WhichKeyController()
        controller.show(after: [Shortcut("j", modifiers: [.command])],
                        rows: [WhichKeyRow(key: "t", title: "New Tab", isEnabled: true)], in: window)
        let host = WindowOverlayHost.existingHost(for: window)
        #expect(host?.hasPresentations == true, "the which-key is a presentation of the host")
        #expect((window.childWindows ?? []).allSatisfy { $0 is OverlayHostPanel }, "no child panel of its own")
        #expect(host?.interactiveRegions().isEmpty == true, "it never takes the mouse")
        controller.hide()
    }
}
