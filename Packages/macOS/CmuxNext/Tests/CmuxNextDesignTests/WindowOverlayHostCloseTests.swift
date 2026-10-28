import AppKit
@testable import CmuxNextDesign
import Testing

/// A window's overlay host panel closes with its window. Ordered out only, it stayed in the app's
/// window list, open, for as long as anything held the host, and work that reached a closed window
/// late made a new panel that nothing closed (the test window census, 2026-10-28).
@MainActor @Suite(.serialized) struct WindowOverlayHostCloseTests {
    private static func window(onScreen: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if onScreen { window.orderFrontRegardless() }
        return window
    }

    private static func toast() -> OverlayOptions {
        OverlayOptions(kind: .toast, anchor: NSRect(x: 10, y: 10, width: 10, height: 10), passesThroughClicks: true)
    }

    /// Calls `body` when `window` closes (its `willClose` notification), until the returned token goes.
    private static func onClose(_ window: NSWindow, _ body: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { body() } // main-proof: observer on queue: .main
        }
    }

    @Test func closingTheWindowClosesItsHostPanel() {
        let window = Self.window(onScreen: true)
        let host = WindowOverlayHost.host(for: window)
        let handle = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)), options: Self.toast())
        #expect(host.isPanelAttached)
        var panelClosed = false
        let token = Self.onClose(host.panel) { panelClosed = true }
        defer { NotificationCenter.default.removeObserver(token) }

        window.close()

        #expect(panelClosed, "the host panel was only ordered out: it stays open in the app's window list")
        #expect(!host.panel.isVisible)
        #expect(!host.isPanelAttached)
        #expect(handle.isDismissed)
        #expect(WindowOverlayHost.existingHost(for: window) == nil)
    }

    @Test func aHostAskedForAfterTheCloseMakesNoNewPanel() {
        let window = Self.window(onScreen: true)
        let host = WindowOverlayHost.host(for: window)
        window.close()

        let late = WindowOverlayHost.host(for: window)
        #expect(late === host, "a closed window got a new host, and so a new panel nothing closes")
        _ = late.present(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)), options: Self.toast())
        #expect(!late.isPanelAttached)
        #expect(!late.panel.isVisible)
        #expect(window.childWindows?.contains { $0 === late.panel } != true)
    }

    /// A host made while the window closes (its controller's teardown makes the overlay layer)
    /// came after the close notification: `windowIsClosing` tears it down too.
    @Test func aHostMadeDuringTheCloseClosesWithIt() throws {
        let window = Self.window(onScreen: true)
        var made: WindowOverlayHost?
        let token = Self.onClose(window) {
            made = WindowOverlayHost.host(for: window)
            WindowOverlayHost.windowIsClosing(window)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        window.close()

        let host = try #require(made)
        #expect(host.isTearingDown)
        #expect(!host.isPanelAttached)
        #expect(WindowOverlayHost.existingHost(for: window) == nil)
        #expect(WindowOverlayHost.host(for: window) === host, "a host made during the close was replaced after it")
    }

    /// A closed window shown again gets a fresh host whose overlays show.
    @Test func aWindowShownAgainGetsOverlaysAgain() {
        let window = Self.window(onScreen: true)
        defer { window.close() }
        let host = WindowOverlayHost.host(for: window)
        window.close()
        window.orderFrontRegardless()

        let again = WindowOverlayHost.host(for: window)
        #expect(again !== host)
        let handle = again.present(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)), options: Self.toast())
        defer { handle.dismiss() }
        #expect(again.isPanelAttached)
        #expect(WindowOverlayHost.existingHost(for: window) === again)
    }

    /// The app's own host (no window) is never torn down by a window's close.
    @Test func aWindowCloseLeavesTheAppHost() {
        let app = WindowOverlayHost.appHost()
        let window = Self.window(onScreen: true)
        _ = WindowOverlayHost.host(for: window)
        window.close()
        WindowOverlayHost.windowIsClosing(window)
        #expect(WindowOverlayHost.appHost() === app)
        #expect(!app.isTearingDown)
    }
}
