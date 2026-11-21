import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// Toggle Pane Zoom and the Swap Pane actions show in the input's turn (store intents), stay through the daemon's
/// older snapshots, go back exactly when the daemon refuses, and the daemon's own `layout-changed` for the same
/// change wakes no reader of the screen's tree. Before, each was a plain `send`: nothing changed until the daemon's
/// echo arrived (one daemon round trip after the key, 50-60 ms for zoom).
@MainActor
struct PaneLayoutIntentTests {
    nonisolated private static let first = PaneID(rawValue: 10)
    nonisolated private static let second = PaneID(rawValue: 20)
    nonisolated private static let third = PaneID(rawValue: 30)
    nonisolated private static let screen = ScreenID(rawValue: 100)

    private static func split(_ a: LayoutNode, _ b: LayoutNode, id: UInt64 = 5) -> LayoutNode {
        .split(id: SplitID(rawValue: id), resourceID: nil, direction: .right, ratio: 0.5, a: a, b: b)
    }

    private static func pair(_ a: PaneID = first, _ b: PaneID = second) -> LayoutNode { split(.leaf(a), .leaf(b)) }

    private static func pane(_ id: PaneID) -> PaneSnapshot {
        PaneSnapshot(id: id, tabs: [TabSnapshot(surface: SurfaceID(rawValue: id.rawValue + 1))])
    }

    /// One workspace, one screen with `layout`; a second screen holds pane 90 alone.
    private static func tree(_ layout: LayoutNode = pair(), zoomed: PaneID? = nil, columns: [ColumnSnapshot] = []) -> DaemonTree {
        let other = PaneID(rawValue: 90)
        return DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [
                ScreenSnapshot(id: screen, active: true, activePane: first, zoomedPane: zoomed, layout: layout, columns: columns,
                               panes: layout.paneIDs.map(pane)),
                ScreenSnapshot(id: 200, activePane: other, layout: .leaf(other), panes: [pane(other)]),
            ]),
        ])
    }

    private static func store(_ tree: DaemonTree = tree()) -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }

    private static func shown(_ store: DaemonStore) throws -> ScreenModel { try #require(store.screen(screen)) }

    /// Counts the changes the tracked readers of the screen's tree and zoom hear.
    @MainActor final class Wakes {
        var count = 0
    }

    private static func track(_ screen: ScreenModel, into wakes: Wakes) {
        withObservationTracking { _ = screen.layout } onChange: { MainActor.assumeIsolated { wakes.count += 1 } }
        withObservationTracking { _ = screen.columns } onChange: { MainActor.assumeIsolated { wakes.count += 1 } }
        withObservationTracking { _ = screen.panes } onChange: { MainActor.assumeIsolated { wakes.count += 1 } }
        withObservationTracking { _ = screen.zoomedPane } onChange: { MainActor.assumeIsolated { wakes.count += 1 } }
    }

    private static func layoutEcho(_ layout: LayoutNode, zoomed: PaneID? = nil, sequence: UInt64 = 1) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .layoutChanged(
            screen: screen, layout: ScreenLayoutDelta(activePane: first, zoomedPane: zoomed, layout: layout), transaction: nil))
    }

    // MARK: Zoom

    @Test func zoomShowsInTheIntentsTurnAndUnzoomIsItsInverse() throws {
        let store = Self.store()
        let screen = try Self.shown(store)
        store.intend(.zoomPane(pane: Self.second, zoomed: true), transaction: .generate())
        #expect(screen.zoomedPane == Self.second)
        #expect(screen.layout == Self.pair(), "zoom keeps the tree")
        store.intend(.zoomPane(pane: Self.second, zoomed: false), transaction: .generate())
        #expect(screen.zoomedPane == nil)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// `off` unzooms the screen whichever pane it shows (cmux-tui's `zoom_pane_as`).
    @Test func unzoomFromAnotherPaneUnzoomsTheScreen() throws {
        let store = Self.store(Self.tree(zoomed: Self.first))
        store.intend(.zoomPane(pane: Self.second, zoomed: false), transaction: .generate())
        #expect(try Self.shown(store).zoomedPane == nil)
    }

    @Test func anOlderSnapshotKeepsTheZoom() throws {
        let store = Self.store()
        store.intend(.zoomPane(pane: Self.second, zoomed: true), transaction: .generate())
        store.apply(snapshot: Self.tree())
        #expect(try Self.shown(store).zoomedPane == Self.second)
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test(arguments: [false, true])
    func aRefusedZoomGoesBackToTheEarlierZoom(zoomedBefore: Bool) throws {
        let earlier = zoomedBefore ? Self.first : nil
        let store = Self.store(Self.tree(zoomed: earlier))
        let transaction = ClientTransactionID.generate()
        store.intend(.zoomPane(pane: Self.second, zoomed: true), transaction: transaction)
        #expect(try Self.shown(store).zoomedPane == Self.second)
        store.rejectIntent(transaction)
        #expect(try Self.shown(store).zoomedPane == earlier)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The daemon's `layout-changed` for a zoom the screen already shows publishes nothing: no second layout pass.
    @Test func theDaemonsEchoOfAShownZoomWakesNoReader() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.zoomPane(pane: Self.second, zoomed: true), transaction: transaction)
        let screen = try Self.shown(store)
        let wakes = Wakes()
        Self.track(screen, into: wakes)
        _ = store.apply(batch: [Self.layoutEcho(Self.pair(), zoomed: Self.second)])
        store.noteSettled(transaction, at: 1)
        #expect(wakes.count == 0, "the daemon's echo of a shown zoom woke \(wakes.count) readers")
        #expect(screen.zoomedPane == Self.second)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A pane that is still opening has no daemon pane to zoom: nothing shows, the command's refusal is the report.
    @Test func aStandInPaneDoesNotZoom() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: Self.first, direction: .right, ratio: 0.5, provisional: provisional), transaction: .generate())
        store.intend(.zoomPane(pane: provisional.handle, zoomed: true), transaction: .generate())
        #expect(try Self.shown(store).zoomedPane == nil)
    }

    // MARK: Swap

    @Test func swapShowsInTheIntentsTurnAndASecondSwapIsItsInverse() throws {
        let store = Self.store()
        let screen = try Self.shown(store)
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: .generate())
        #expect(screen.layout == Self.pair(Self.second, Self.first), "the two panes changed places; the split and its ratio stay")
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: .generate())
        #expect(screen.layout == Self.pair())
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The intent names the order, so the pane the action ran on does not matter and a repeat changes nothing.
    @Test func theSwapIntentNamesTheResultingOrder() throws {
        let store = Self.store()
        #expect(store.swapIntent(of: Self.first, with: Self.second) == store.swapIntent(of: Self.second, with: Self.first))
        let intent = store.swapIntent(of: Self.second, with: Self.first)
        store.intend(intent, transaction: .generate())
        store.intend(intent, transaction: .generate())
        #expect(try Self.shown(store).layout == Self.pair(Self.second, Self.first), "the same intent twice is one swap")
    }

    @Test func anOlderSnapshotKeepsTheSwap() throws {
        let store = Self.store()
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: .generate())
        store.apply(snapshot: Self.tree())
        #expect(try Self.shown(store).layout == Self.pair(Self.second, Self.first))
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func aRefusedSwapPutsThePanesBack() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: transaction)
        store.rejectIntent(transaction)
        #expect(try Self.shown(store).layout == Self.pair())
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The daemon's `layout-changed` for a swap the screen already shows publishes nothing: no second layout pass.
    @Test func theDaemonsEchoOfAShownSwapWakesNoReader() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: transaction)
        let screen = try Self.shown(store)
        let wakes = Wakes()
        Self.track(screen, into: wakes)
        _ = store.apply(batch: [Self.layoutEcho(Self.pair(Self.second, Self.first))])
        store.noteSettled(transaction, at: 1)
        #expect(wakes.count == 0, "the daemon's echo of a shown swap woke \(wakes.count) readers")
        #expect(screen.layout == Self.pair(Self.second, Self.first))
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A batch about something else, while the swap waits for its reply, also publishes nothing to the screen.
    @Test func anUnrelatedBatchWakesNoReaderOfAPendingSwap() throws {
        let store = Self.store()
        store.intend(store.swapIntent(of: Self.first, with: Self.second), transaction: .generate())
        store.intend(.zoomPane(pane: Self.first, zoomed: true), transaction: .generate())
        let screen = try Self.shown(store)
        let wakes = Wakes()
        Self.track(screen, into: wakes)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 91, title: "busy"))])
        #expect(wakes.count == 0)
        #expect(screen.layout == Self.pair(Self.second, Self.first) && screen.zoomedPane == Self.first)
    }

    /// Columns and rows hold the panes too (cmux-tui's `swap_layout_panes`): every tree that places them changes.
    @Test func swapChangesColumnsAndRows() throws {
        let rows = ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: Self.pair(Self.second, Self.third),
                                  rows: [RowSnapshot(id: RowID(rawValue: 1), height: 500, layout: .leaf(Self.second)),
                                         RowSnapshot(id: RowID(rawValue: 2), height: 500, layout: .leaf(Self.third))])
        let columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: .leaf(Self.first)), rows]
        let layout = Self.split(.leaf(Self.first), Self.pair(Self.second, Self.third), id: 6)
        let store = Self.store(Self.tree(layout, columns: columns))
        let transaction = ClientTransactionID.generate()
        store.intend(store.swapIntent(of: Self.third, with: Self.first), transaction: transaction)
        let screen = try Self.shown(store)
        #expect(screen.layout.paneIDs == [Self.third, Self.second, Self.first])
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.third], [Self.second, Self.first]])
        #expect(screen.columns[1].rows.map(\.layout.paneIDs) == [[Self.second], [Self.first]])
        #expect(screen.columns.map(\.width) == [0.5, 0.5] && screen.columns[1].rows.map(\.height) == [500, 500], "sizes stay with the place")
        store.rejectIntent(transaction)
        #expect(screen.layout == layout && screen.columns == columns)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// cmux-tui's `swap_leaf_ids`: a stack that holds one of the two and showed it expanded shows the other expanded;
    /// a stack that holds both keeps its expanded pane.
    @Test func swapKeepsAStacksExpandedRule() {
        let one = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                   a: .stack(panes: [Self.first, Self.second], expanded: Self.first), b: .leaf(Self.third))
        #expect(one.swappingPanes(Self.first, Self.third) == .split(
            id: nil, resourceID: nil, direction: .right, ratio: 0.5,
            a: .stack(panes: [Self.third, Self.second], expanded: Self.third), b: .leaf(Self.first)))
        let both = LayoutNode.stack(panes: [Self.first, Self.second], expanded: Self.first)
        #expect(both.swappingPanes(Self.first, Self.second) == .stack(panes: [Self.second, Self.first], expanded: Self.first))
        #expect(one.swappingPanes(Self.first, Self.third).swappingPanes(Self.first, Self.third) == one, "its own inverse")
    }

    /// What the daemon refuses shows nothing: a pane of another screen, the pane itself, a pane that is still opening.
    @Test func aSwapTheDaemonRefusesShowsNothing() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: Self.second, direction: .right, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try Self.shown(store)
        let before = screen.layout
        for other in [PaneID(rawValue: 90), Self.first, provisional.handle] {
            store.intend(store.swapIntent(of: Self.first, with: other), transaction: .generate())
            #expect(screen.layout == before)
        }
        #expect(store.mirrorViolations.isEmpty)
    }
}
