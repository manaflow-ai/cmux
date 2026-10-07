import AppKit
@testable import CmuxNextApp
import Testing

/// Quitting ends every open sheet (result, status, confirmation) as
/// cancelled, so termination never waits on one. GUI lane only: runs on
/// cmux-lawrence-2, excluded on headless workers (`WindowSession`).
@MainActor
@Suite(.enabled(if: WindowSession.available, WindowSession.reason)) struct QuitSheetTests {
    @Test func dismissingSheetsCancelsThemAndDetachesThem() async {
        // Accessory: no Dock icon; the window sits far off every screen.
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let alert = NSAlert()
        alert.messageText = "status"
        var response: NSApplication.ModalResponse?
        alert.beginSheetModal(for: window) { response = $0 }
        #expect(window.attachedSheet != nil)

        let ended = SheetDismissal.endAll(in: [window])
        #expect(ended == 1)
        #expect(window.attachedSheet == nil)
        #expect(response == .cancel)
        window.close()
    }
}
