import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The scheduler pilot in the notifications (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// 205): the panel's ledger watch evaluates nothing while the panel is closed and reads once when it
/// shows; the service's arrivals flush once per frame however many came, and never in the
/// arrival's own turn.
@MainActor
struct NotificationsPilotTests {
    /// One workspace whose only tab is on surface 1.
    private static func store() -> DaemonStore {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    private static func arrive(_ id: UInt64, in store: DaemonStore) throws {
        let wire = #"{"notification":\#(id),"title":"Done","body":"","level":"info","surface":1,"source":"agent"}"#
        store.apply(.notification(try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))))
    }

    @Test func aClosedPanelEvaluatesNothingAndReadsOnceWhenItShows() throws {
        let frames = NotificationFrames()
        let store = Self.store()
        let node = VisibilityNode(root: "notifications.panel", own: .visible)
        var reads = 0
        var applied: [NotificationsPanelController.LedgerMark] = []
        let watch = VisibleObservation(node, owner: "test.notifications.panel", on: frames.work) {
            reads += 1
            return NotificationsPanelController.LedgerMark(store)
        } apply: { applied.append($0) }
        #expect(reads == 1 && applied.count == 1, "the open panel reads the ledger state once")
        // Hiding fires the armed tracking once, so the registrar drops it.
        node.set(.hidden)
        let callbacksWhenClosed = watch.trackingCallbacks
        for id in 1...100 { try Self.arrive(UInt64(id), in: store) }
        frames.frame()
        frames.frame()
        #expect(reads == 1, "a closed panel evaluated its ledger watch \(reads - 1) times")
        #expect(watch.trackingCallbacks == callbacksWhenClosed, "a closed panel's tracking still fired")
        node.set(.visible)
        #expect(reads == 2, "the panel reads once when it shows")
        #expect(applied.last?.newest == 100)
        #expect(applied.count == 2)
    }

    @Test func manyArrivalsInOneTurnFlushOnceOnTheNextFrame() throws {
        let frames = NotificationFrames()
        let store = Self.store()
        var evaluations = 0
        var newest: [UInt64] = []
        let arrivals = ServiceObservation(.visible, owner: "test.notifications.arrivals", on: frames.work) {
            evaluations += 1
            return store.notifications.last?.notification.rawValue ?? 0
        } apply: { newest.append($0) }
        for id in 1...50 { try Self.arrive(UInt64(id), in: store) }
        #expect(newest == [0], "nothing flushes in the arrivals' own turn")
        frames.frame()
        #expect(evaluations == 2, "fifty arrivals, one evaluation")
        #expect(newest == [0, 50])
        withExtendedLifetime(arrivals) {}
    }
}
