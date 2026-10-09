import Foundation
import Testing
@testable import CmuxNextDaemon

/// T1 (plans/cmux-next/remote-state-ownership.md S3): Cmd+D shows the new pane in the input's
/// frame. The split intent puts a provisional pane beside the target in the store's visible
/// layout before any reply, under the client-minted ids the request sends; a refusal removes it
/// exactly; the daemon's pane with the same public id replaces it without ever showing both.
@MainActor @Suite struct SplitIsProvisionalTests {
    private func loaded() throws -> (DaemonStore, DaemonTree) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        return (store, tree)
    }

    /// Screen 17 holds only pane 16 and has no columns; screen 5 has columns, pane 11 in the first.
    private func screen(_ store: DaemonStore, _ handle: ScreenID) throws -> ScreenModel {
        try #require(store.screen(handle))
    }

    private func panes(withResource id: String, in store: DaemonStore) -> [PaneModel] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.resourceID?.rawValue == id }
    }

    @Test func aSplitShowsTheProvisionalPaneBeforeTheReply() throws {
        let (store, _) = try loaded()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 16, direction: .right, ratio: 0.5, provisional: provisional), transaction: "tx")
        let screen = try screen(store, 17)
        #expect(screen.layout.paneIDs == [16, provisional.handle])
        if case .split(_, let direction, let ratio, _, _) = screen.layout {
            #expect(direction == .right)
            #expect(ratio == 0.5)
        } else {
            Issue.record("screen 17 is not split: \(screen.layout)")
        }
        let pane = try #require(store.pane(provisional.handle))
        #expect(pane.resourceID?.rawValue == provisional.paneID)
        #expect(pane.tabs.map(\.surface) == [provisional.surface])
        #expect(pane.tabs.first?.snapshot.tabResourceID?.rawValue == provisional.tabID)
        #expect(screen.panes.contains { $0.handle == provisional.handle })
    }

    @Test func aSplitInAColumnChangesThatColumnsTree() throws {
        let (store, _) = try loaded()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 11, direction: .down, ratio: 0.5, provisional: provisional), transaction: "tx")
        let screen = try screen(store, 5)
        let column = try #require(screen.columns.first { $0.layout.paneIDs.contains(11) })
        #expect(column.layout.paneIDs.contains(provisional.handle))
        #expect(screen.layout.paneIDs.contains(provisional.handle))
        #expect(screen.columns.filter { $0.layout.paneIDs.contains(provisional.handle) }.count == 1)
    }

    @Test func aRefusedSplitRemovesTheProvisionalPaneExactly() throws {
        let (store, _) = try loaded()
        let before = try screen(store, 5).layout
        let columns = try screen(store, 5).columns
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 11, direction: .down, ratio: 0.5, provisional: provisional), transaction: "tx")
        #expect(store.pane(provisional.handle) != nil)
        store.rejectIntent("tx")
        #expect(store.pane(provisional.handle) == nil)
        #expect(try screen(store, 5).layout == before)
        #expect(try screen(store, 5).columns == columns)
        #expect(store.tabsBySurface[provisional.surface] == nil)
    }

    /// The daemon's pane (another numeric handle, the same public id) arrives in a snapshot before
    /// the reply settles the intent: it replaces the provisional pane in that apply.
    @Test func theDaemonsPaneReplacesTheProvisionalOneWithoutADuplicate() throws {
        let (store, tree) = try loaded()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 16, direction: .right, ratio: 0.5, provisional: provisional), transaction: "tx")
        var confirmed = tree
        let workspace = try #require(confirmed.workspaces.firstIndex { $0.screens.contains { $0.id == 17 } })
        let index = try #require(confirmed.workspaces[workspace].screens.firstIndex { $0.id == 17 })
        var screen = confirmed.workspaces[workspace].screens[index]
        screen.layout = .split(id: 90, direction: .right, ratio: 0.5, a: .leaf(16), b: .leaf(91))
        screen.panes.append(PaneSnapshot(id: 91, resourceID: ResourceID(rawValue: provisional.paneID),
                                         tabs: [TabSnapshot(surface: 92, tabResourceID: ResourceID(rawValue: provisional.tabID))]))
        confirmed.workspaces[workspace].screens[index] = screen
        store.apply(snapshot: confirmed)
        #expect(panes(withResource: provisional.paneID, in: store).map(\.handle) == [91])
        #expect(store.pane(provisional.handle) == nil)
        #expect(try self.screen(store, 17).layout.paneIDs == [16, 91])
        store.noteSettled("tx", at: 1)
        #expect(panes(withResource: provisional.paneID, in: store).map(\.handle) == [91])
    }

    @Test func aSplitOfAPaneTheStoreDoesNotHaveChangesNothing() throws {
        let (store, _) = try loaded()
        let before = store.workspaces.flatMap(\.screens).map(\.layout)
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 999, direction: .right, ratio: 0.5, provisional: provisional), transaction: "tx")
        #expect(store.pane(provisional.handle) == nil)
        #expect(store.workspaces.flatMap(\.screens).map(\.layout) == before)
    }
}
