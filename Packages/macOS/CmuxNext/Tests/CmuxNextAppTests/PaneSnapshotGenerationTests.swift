import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import os
import Testing

/// A pane's strip snapshot (`PaneController.structure()`) observes only what the strip draws. It
/// also read the store's daemon generation into a field nothing uses (1b1311983c52), so the
/// generation a relaunch's first tree sets re-ran every restored pane's snapshot: whether it came
/// before or after the panes mounted decided the perf gate's relaunch count (budget 1 snapshot per
/// pane; 4.0 on 10-19, 2.0 on one 10-21 run).
@MainActor struct PaneSnapshotGenerationTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    @Test func aNewDaemonGenerationDoesNotRerunTheStripSnapshot() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        defer { pane.teardown() }

        let reran = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking { pane.structure() } onChange: { reran.withLock { $0 = true } }
        store.generation = DaemonGeneration(rawValue: "relaunched")

        #expect(!reran.withLock { $0 }, "the daemon's generation re-ran the pane's strip snapshot; the strip does not draw it")
    }
}
