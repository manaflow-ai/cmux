import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home transcript read its window place (two layer conversions and a compare) after
/// every `NSWindow.didUpdateNotification`, once per event of the window (each key typed in the field). Now
/// it reads the place after the window's layout pass (`MessagesLabHomeView.windowDidLayout`, which the app
/// calls from the window's `WindowLayoutPasses`), where an ancestor's move happens: window events with no
/// layout read nothing, and an ancestor's move refreshes the rows once.
@MainActor @Suite(.serialized) struct HomeWindowPlaceFollowTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        /// The pane container: it moves the transcript without laying it out (a sidebar or divider drag).
        let pane: NSView
        let view: MessagesLabHomeView
        var host: HostView { view.controller.host }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 12, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let pane = NSView(frame: NSRect(x: 100, y: 0, width: 700, height: 900))
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = pane.bounds
        pane.addSubview(view)
        root.addSubview(pane)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        view.projection.refresh()
        view.controller.host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return Rig(store: store, window: window, pane: pane, view: view)
    }

    @Test func aHundredWindowUpdatesReadNoWindowPlace() async throws {
        let r = try await rig()
        defer { r.close() }
        let refreshes = r.host.windowPlaceRefreshes

        // AppKit posts didUpdate once per event of the window (window.update()): the stand-in for 100 keys.
        for _ in 0..<100 { r.window.update() }

        #expect(r.host.windowPlaceRefreshes == refreshes, "a window update read the transcript's window place")
    }

    @Test func anAncestorMoveRefreshesTheRowsOnceAtTheLayoutPass() async throws {
        let r = try await rig()
        defer { r.close() }
        let refreshes = r.host.windowPlaceRefreshes

        // A layout pass that moved nothing refreshes nothing.
        r.view.windowDidLayout()
        #expect(r.host.windowPlaceRefreshes == refreshes, "an unmoved transcript refreshed its rows")

        // The pane moved by a fraction of a point with no size change: nothing lays the transcript out.
        r.pane.setFrameOrigin(NSPoint(x: 160.5, y: 0))
        r.view.windowDidLayout()
        #expect(r.host.windowPlaceRefreshes == refreshes + 1, "the window's layout pass missed the ancestor's move")

        r.view.windowDidLayout()
        #expect(r.host.windowPlaceRefreshes == refreshes + 1, "a second pass with no move refreshed the rows again")
    }
}
