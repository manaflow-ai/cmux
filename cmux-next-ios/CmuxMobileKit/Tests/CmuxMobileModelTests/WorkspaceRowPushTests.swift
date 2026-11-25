import CmuxMobileModel
import Foundation
import Testing

/// A Mac's row push (`updateWorkspaces`) is one change of `workspaces`, however many rows it
/// carries: each reader (the open terminal's composer among them) re-renders once per push,
/// not once per row, and a push that changes nothing notifies no one (ask-4a87599079: typing
/// in the composer followed the Mac's load).
@MainActor
@Suite struct WorkspaceRowPushTests {
    static func rows(_ count: Int) -> [Workspace] {
        (0..<count).map {
            Workspace(id: "w\($0)", macID: "m", title: "w\($0)", directory: "~", tabs: [],
                      lastActivityAt: Date(timeIntervalSince1970: 1_000))
        }
    }

    /// How many changes of `workspaces` (each one notifies every reader) `change` made.
    func changes(_ store: AppStore, _ change: () -> Void) -> Int {
        let revision = store.workspacesRevision
        change()
        return store.workspacesRevision - revision
    }

    @Test func aPushOfEightRowsIsOneChange() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: Self.rows(150), feed: [], tabMemory: .inMemory())
        var pushed = Array(store.workspaces.prefix(8))
        for index in pushed.indices { pushed[index].isWorking = true }
        let count = changes(store) { store.updateWorkspaces(macID: "m", rows: pushed) }
        #expect(count == 1)
        #expect(store.workspaces.prefix(8).allSatisfy { $0.isWorking })
        #expect(!store.workspaces.dropFirst(8).contains { $0.isWorking })
    }

    @Test func aPushThatChangesNothingIsNoChange() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: Self.rows(20), feed: [], tabMemory: .inMemory())
        let same = Array(store.workspaces.prefix(8))
        let count = changes(store) { store.updateWorkspaces(macID: "m", rows: same) }
        #expect(count == 0)
    }

    @Test func anotherMacsRowsAreLeftAlone() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: Self.rows(4), feed: [], tabMemory: .inMemory())
        var other = store.workspaces[0]
        other.macID = "elsewhere"
        other.isWorking = true
        let count = changes(store) { store.updateWorkspaces(macID: "elsewhere", rows: [other]) }
        #expect(count == 0)
        #expect(!store.workspaces[0].isWorking)
    }
}
