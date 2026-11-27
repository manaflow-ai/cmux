import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// A select that names a tab its pane's record holds before the pane's strip maps it still selects it.
/// The strip follows the record one main-actor hop later (its observation), and the focus reducer checks
/// a selected tab against the topology, which is built from the strip. Before, a select in that gap was
/// dropped as a stale request and nothing tried it again: BrowserSamePaneReuseTests timed out on macOS 27
/// (fleet job 4df3398d: the record listed the new tab, the strip and the topology did not), and a strip,
/// shortcut, palette or CLI select (`PaneController.select`) of a tab made a moment before was lost the same way.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct SelectBeforeStripMapsTests {
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aSelectInTheTurnTheRecordGainsItsTabSelectsIt() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.focusedPane)
            let created = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit,
                                                                      in: pane.pane.handle, activate: true)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil })
            let model = try #require(services.daemon.store.tab(surface: created.surface))
            try await PinnedPageTests.until({ pane.stripModel.tabs.contains { $0.id.rawValue == model.id } })
            let first = try #require(pane.pane.tabs.first { $0.id != model.id })
            pane.select(TabID(first.id), source: .intent)
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == first.id })

            // The gap, made in one main-actor turn: the strip maps the record without the tab, then the record
            // holds it again, as when a daemon delta adds a tab before the strip's observation runs.
            let tabs = pane.pane.tabs
            pane.pane.tabs = tabs.filter { $0.id != model.id }
            pane.syncStripFromStore()
            pane.pane.tabs = tabs
            try #require(pane.stripIsStale, "the strip already lists the tab: this test makes no gap")
            pane.select(TabID(model.id), source: .intent)

            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == model.id }, report: {
                "strip selected \(pane.stripModel.selectedID?.rawValue ?? "nil"), strip tabs \(pane.stripModel.tabs.map(\.id.rawValue)), "
                    + "topology selected \(pane.workspace?.focus.state.topology.pane(pane.paneKey)?.selected ?? "nil")"
            })
        }
    }
}
