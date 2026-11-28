import CmuxNextLayout
import CmuxNextSettings
import Testing

/// `debug.dock`'s `window_docks`: each edge dock with its hidden flag, so a probe can read Show/Hide Dock.
@Suite struct DebugDockWindowDocksTests {
    @Test func reportsEachEdgeDockAndItsHiddenFlag() {
        var docks = WindowDocks()
        docks.dock("ws-logs", at: .right)
        let shown = docks.debugRows(window: "w1").compactMap(JSONValue.init(foundation:))
        #expect(shown == [
            .object(["window": .string("w1"), "edge": .string("right"), "workspace": .string("ws-logs"),
                     "mode": .string(DockMode.docked.rawValue), "hidden": .bool(false)]),
        ])
        #expect(docks.toggle(.right) == .hidden)
        let hidden = docks.debugRows(window: "w1").compactMap(JSONValue.init(foundation:))
        #expect(hidden.count == 1)
        guard case .object(let fields) = hidden.first else { Issue.record("not an object"); return }
        #expect(fields["hidden"] == .bool(true))
    }

    @Test func emptyFrameReportsNoDocks() {
        #expect(WindowDocks().debugRows(window: "w1").isEmpty)
    }
}
