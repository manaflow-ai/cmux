import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// HOT PATH AUDIT frames (cmd-tab): one Cmd-Tab back to cmux posts `NSApplication.didBecomeActive` and
/// `NSWindow.didBecomeMain` in the same turn. Each notice walked every status indicator the app ever made (a bridged
/// `allObjects` array of all of them, and each one's ancestor walk to find whether it shows), so one activation paid
/// that walk twice. The moments of one turn are one moment: the first runs at once, the rest of that turn are no-ops.
@MainActor @Suite(.serialized, .closesItsWindows) struct CmdTabOneResyncPassTests {
    @MainActor private final class Counter: StatusIndicatorConfigClient {
        var resyncs = 0
        func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {}
        func statusIndicatorResync() { resyncs += 1 }
    }

    @Test func oneActivationIsOneResyncPass() {
        let app = NotificationCenter()
        let appearance = StatusIndicatorAppearance(appCenter: app, workspaceCenter: NotificationCenter())
        let clients = (0..<50).map { _ in Counter() }
        for client in clients { appearance.register(client) }
        // Cmd-Tab: the app becomes active and its window becomes main in one turn.
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        app.post(name: NSWindow.didBecomeMainNotification, object: nil)
        #expect(clients.allSatisfy { $0.resyncs == 1 }, "one activation resynced each indicator \(clients.first?.resyncs ?? 0) times")
    }
}
