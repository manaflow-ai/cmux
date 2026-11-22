import Foundation
import Testing
@testable import CmuxNextDaemon

/// New Column Left (`new-pane-right {side: "left"}`, `column-left-v1`): the request names the side
/// only when it is left, and the optimistic column shows before the pane's column in the key's turn.
@MainActor
struct NewColumnLeftTests {
    private static let pane = PaneID(rawValue: 3)
    private static let other = PaneID(rawValue: 5)
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000002")

    @Test func theRequestSendsSideLeftOnlyForLeft() throws {
        func json(_ request: NewColumnRequest) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        #expect(try json(NewColumnRequest(pane: Self.pane, width: 0.5, left: true))["side"] as? String == "left")
        #expect(try json(NewColumnRequest(pane: Self.pane, width: 0.5))["side"] == nil)
    }

    @Test func theOptimisticColumnShowsBeforeThePanesColumn() throws {
        let store = DaemonStore()
        let tree = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "1",
            screens: [ScreenSnapshot(
                id: ScreenID(rawValue: 2), active: true, activePane: Self.other,
                layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(Self.other)),
                columns: [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: .leaf(Self.pane)),
                          ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: .leaf(Self.other))],
                panes: [PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))]),
                        PaneSnapshot(id: Self.other, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 6))])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        let provisional = ProvisionalPane(columnWidth: 2.0 / 3.0, left: true)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.other, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let screen = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane], [provisional.handle], [Self.other]])
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle, Self.other])
        store.rejectIntent(transaction)
        let after = try #require(store.workspace(id: Self.key.rawValue)?.screens.first)
        #expect(after.columns.map(\.layout.paneIDs) == [[Self.pane], [Self.other]])
        #expect(store.mirrorViolations.isEmpty)
    }
}
