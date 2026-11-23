import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// instant-splits (Leo, 2026-11-04: "never, ever ... be acceptable for there to be some sort of linear time growth
/// degradation"). While a split is pending (Cmd-D, New Column, New Row), the intent overlay takes its provisional pane
/// out of the screen's tree before every daemon batch and puts it back after (`withOverlayLifted`). Each round trip
/// wrote the screen's `layout`, `columns` and `panes` twice, so every tracked reader of the shown workspace's tree (its
/// content's layout mapping, every pane controller's strip, which reads the screen's columns) mapped again on each
/// batch, though the batch was about another workspace: background workspaces' busy terminals made the shown
/// workspace re-map through the split's own frames. A batch publishes only its net change to the tree, once.
@MainActor
struct SplitOverlayNetPublishTests {
    static let count = 30

    /// Workspace `index`: one screen, one pane, one terminal tab.
    static func workspace(_ index: Int) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        let pane = PaneID(rawValue: base)
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: String(format: "k%03d", index)),
                                 name: "w\(index)",
                                 screens: [ScreenSnapshot(id: ScreenID(rawValue: base), active: true, activePane: pane, layout: .leaf(pane),
                                                          panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 1))])])])
    }

    static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<count).map(workspace)))
        return store
    }

    /// The shown workspace's pane (workspace 0's).
    static let shownPane = PaneID(rawValue: 100)

    /// A daemon batch about background workspace `index` alone: a terminal tab opens in its pane.
    static func tabOpened(in index: Int, sequence: UInt64) -> DaemonEventEnvelope {
        let base = UInt64(index + 1) * 100
        let surface = SurfaceID(rawValue: base + 10 + sequence)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: UInt64(index + 1)), screen: ScreenID(rawValue: base), pane: PaneID(rawValue: base),
            surface: surface, index: 1, entity: TabSnapshot(surface: surface), clientTransactionID: nil)))
    }

    /// Counts the changes the tracked readers of the shown screen's tree hear.
    @MainActor final class Wakes {
        var layout = 0
        var columns = 0
        var panes = 0
        var total: Int { layout + columns + panes }
    }

    static func track(_ screen: ScreenModel, into wakes: Wakes) {
        withObservationTracking { _ = screen.layout } onChange: { MainActor.assumeIsolated { wakes.layout += 1 } }
        withObservationTracking { _ = screen.columns } onChange: { MainActor.assumeIsolated { wakes.columns += 1 } }
        withObservationTracking { _ = screen.panes } onChange: { MainActor.assumeIsolated { wakes.panes += 1 } }
    }

    static func shownScreen(_ store: DaemonStore) throws -> ScreenModel {
        try #require(store.workspace(id: "k000")?.screens.first)
    }

    /// RED at base: every batch about a background workspace wrote the shown screen's tree twice (the lift took the
    /// split's pane out, the restore put it back). GREEN: such a batch publishes nothing to the shown screen.
    @Test(arguments: [false, true])
    func aBatchAboutABackgroundWorkspaceWakesNoReaderOfTheSplitScreen(newColumn: Bool) throws {
        let store = Self.store()
        let provisional = newColumn ? ProvisionalPane(columnWidth: 0.5) : ProvisionalPane()
        store.intend(.splitPane(pane: Self.shownPane, direction: .right, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try Self.shownScreen(store)
        #expect(screen.panes.map(\.handle) == [Self.shownPane, provisional.handle], "the split shows in the intent's turn")
        let wakes = Wakes()
        Self.track(screen, into: wakes)

        // The bound: one batch per background workspace (30 busy terminals), none reaches the shown screen.
        for index in 1..<Self.count { _ = store.apply(batch: [Self.tabOpened(in: index, sequence: UInt64(index))]) }

        #expect(wakes.total == 0, "\(Self.count - 1) batches about background workspaces woke the shown screen's readers (layout \(wakes.layout), columns \(wakes.columns), panes \(wakes.panes))")
        // The visible state is the same: the split still shows, the batches' tabs are in their own workspaces.
        #expect(screen.panes.map(\.handle) == [Self.shownPane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
        if newColumn { #expect(screen.columns.map(\.layout.paneIDs) == [[Self.shownPane], [provisional.handle]]) }
        #expect(store.workspace(id: "k007")?.screens.first?.panes.first?.tabs.count == 2)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// What does change the tree still reaches its readers, once, at the lift's end: a refusal takes the split out.
    @Test func aRefusalPublishesTheTreeOnce() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.shownPane, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let screen = try Self.shownScreen(store)
        let wakes = Wakes()
        Self.track(screen, into: wakes)

        store.rejectIntent(transaction)

        #expect(wakes.layout == 1 && wakes.panes == 1, "the refusal's readers heard it (layout \(wakes.layout), panes \(wakes.panes))")
        #expect(wakes.columns == 0, "a split-tree screen's columns did not change")
        #expect(screen.panes.map(\.handle) == [Self.shownPane])
        #expect(screen.layout == .leaf(Self.shownPane))
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// Without a pending split nothing is held: a daemon write to the screen publishes as it always did.
    @Test func aScreenWithNoPendingSplitPublishesEveryWrite() throws {
        let store = Self.store()
        let screen = try Self.shownScreen(store)
        let wakes = Wakes()
        Self.track(screen, into: wakes)
        let other = PaneID(rawValue: 150)
        var tree = (0..<Self.count).map(Self.workspace)
        tree[0].screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.shownPane), b: .leaf(other))
        tree[0].screens[0].panes.append(PaneSnapshot(id: other, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 151))]))

        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: tree))

        #expect(wakes.layout == 1 && wakes.panes == 1, "layout \(wakes.layout), panes \(wakes.panes)")
        #expect(screen.panes.map(\.handle) == [Self.shownPane, other])
    }
}
