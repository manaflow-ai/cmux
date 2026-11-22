import Foundation
import Testing
@testable import CmuxNextDaemon

/// Split Up and Split Left in the key's turn (`split {before: true}`, `split-before-v1`). Leo 2026-11-08, on a bottom
/// pane opening upward: "target gets recalculated ... shit lags". Split Up was `split` (below) then `swap-pane`, so it
/// could not show before the daemon made it, and the swap crossed the new pane over its neighbour mid-motion. Now the
/// daemon makes it before its target in one split, so the overlay shows it there at once, and the daemon's layout is
/// the one already shown: nothing moves when it lands.
@MainActor
struct SplitBeforeOverlayTests {
    private static let pane = PaneID(rawValue: 3)
    private static let daemonPane = PaneID(rawValue: 9)
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000003")
    private static let paneResource = "pane_00000000000000000000000000000003"

    private static func workspace(layout: LayoutNode, panes: [PaneSnapshot]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "1",
                          screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: layout, panes: panes)])
    }

    private static let target = PaneSnapshot(id: pane, resourceID: ResourceID(rawValue: paneResource),
                                             tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace(layout: .leaf(pane), panes: [target])]))
        return store
    }

    /// The screen's split as public ids: its direction, ratio, public id and its two sides' pane ids in order.
    private struct Shown: Equatable {
        var direction: SplitDirection
        var ratio: Double
        var split: String?
        var panes: [String?]
    }

    private static func shown(_ store: DaemonStore) throws -> Shown {
        let screen = try #require(store.workspace(id: key.rawValue)?.screens.first)
        guard case let .split(_, resourceID, direction, ratio, a, b) = screen.layout,
              case let .leaf(first) = a, case let .leaf(second) = b else {
            Issue.record("the screen is not one split of two panes: \(screen.layout)")
            throw CancellationError()
        }
        let ids = [first, second].map { handle in store.panesByHandle[handle]?.resourceID?.rawValue }
        return Shown(direction: direction, ratio: ratio, split: resourceID?.rawValue, panes: ids)
    }

    @Test func theRequestSendsBeforeOnlyWhenTheNewPaneGoesFirst() throws {
        func json(_ request: SplitRequest) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        #expect(try json(SplitRequest(pane: Self.pane, direction: .down, before: true))["before"] as? Bool == true)
        #expect(try json(SplitRequest(pane: Self.pane, direction: .down))["before"] == nil)
    }

    /// The key's turn shows the new pane on its side, and the daemon's confirm (its pane under the client ids, its
    /// split under the client split id, new pane first) shows the same split: same side, same ratio, same id.
    @Test(arguments: [SplitDirection.down, .right])
    func aSplitBeforeShowsTheDaemonsLayoutInTheKeysTurn(direction: SplitDirection) throws {
        let store = Self.store()
        let provisional = ProvisionalPane().placed(before: true)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: direction, ratio: 0.5, provisional: provisional), transaction: transaction)
        let atKey = try Self.shown(store)
        #expect(atKey == Shown(direction: direction, ratio: 0.5, split: provisional.splitID, panes: [provisional.paneID, Self.paneResource]))
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [provisional.handle, Self.pane], "the daemon lists panes in layout order")

        // cmux-tui's `split {before: true}` (split_before_tests.rs): the new pane is `a`, at 0.5, under the client ids.
        let daemonLayout = LayoutNode.split(id: SplitID(rawValue: 20), resourceID: ResourceID(rawValue: provisional.splitID),
                                            direction: direction, ratio: 0.5, a: .leaf(Self.daemonPane), b: .leaf(Self.pane))
        let made = PaneSnapshot(id: Self.daemonPane, resourceID: ResourceID(rawValue: provisional.paneID),
                                tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7), tabResourceID: ResourceID(rawValue: provisional.tabID))])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.workspace(layout: daemonLayout, panes: [made, Self.target])]))
        #expect(try Self.shown(store) == atKey, "the daemon's layout differs from the one shown at the key")
        let confirmed = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(confirmed.panes.map { $0.resourceID?.rawValue } == [provisional.paneID, Self.paneResource])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A pane without `before` keeps opening after its target (Cmd-D, Cmd-Shift-D).
    @Test func aSplitWithoutBeforeStillOpensAfterItsTarget() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: .generate())
        #expect(try Self.shown(store).panes == [Self.paneResource, provisional.paneID])
    }

    /// A refused Split Up leaves the pane as it was.
    @Test func aRefusedSplitBeforeLeavesNothing() throws {
        let store = Self.store()
        let provisional = ProvisionalPane().placed(before: true)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: transaction)
        store.rejectIntent(transaction)
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(screen.layout == .leaf(Self.pane))
        #expect(screen.panes.map(\.handle) == [Self.pane])
        #expect(store.mirrorViolations.isEmpty)
    }
}
