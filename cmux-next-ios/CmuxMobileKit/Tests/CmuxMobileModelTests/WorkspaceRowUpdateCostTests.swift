import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxMobileModel

/// A busy Mac publishes changed rows once a display frame (`updateWorkspaces`). One publication
/// is one change of `workspaces`: one revision, one notification, one write per changed row,
/// and the attention badge moved by those rows alone. Each row written on its own bumped the
/// revision, copied and compared the whole list and recounted the badge per row.
@MainActor
@Suite struct WorkspaceRowUpdateCostTests {
    static func workspace(_ index: Int, mac: String = "m1", attention: Bool = false, title: String? = nil) -> Workspace {
        Workspace(id: "w\(index)", macID: mac, title: title ?? "Workspace \(index)", directory: "~/src",
                  tabs: [WorkspaceTab(id: "t\(index)", kind: .terminal, title: "zsh", subtitle: "~/src")],
                  lastActivityAt: Date(timeIntervalSince1970: 1_000_000 + Double(index)), needsAttention: attention)
    }

    static func store(count: Int) -> AppStore {
        AppStore(teams: [Team(id: "t", name: "T", macs: [MacDevice(id: "m1", name: "Mac", isOnline: true)])],
                 activeTeamID: "t", workspaces: (0..<count).map { workspace($0) }, feed: [], tabMemory: .inMemory())
    }

    @Test func onePublicationIsOneChangeOfTheList() {
        let store = Self.store(count: 500)
        let notifications = Mutex(0)
        withObservationTracking { _ = store.workspaces } onChange: { notifications.withLock { $0 += 1 } }
        let before = store.workspacesRevision
        let rows = [Self.workspace(3, title: "renamed"), Self.workspace(250, attention: true), Self.workspace(499, title: "x")]
        store.updateWorkspaces(macID: "m1", rows: rows)
        #expect(store.workspacesRevision == before + 1)
        #expect(notifications.withLock { $0 } == 1)
        #expect(store.workspaces[3].title == "renamed")
        #expect(store.workspaces[250].needsAttention)
        #expect(store.workspaces[499].title == "x")
        #expect(store.attentionCount == 1)
    }

    @Test func unchangedRowsChangeNothing() {
        let store = Self.store(count: 50)
        let before = store.workspacesRevision
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace(1), Self.workspace(2)])
        #expect(store.workspacesRevision == before)
    }

    @Test func theBadgeFollowsChangedRowsAcrossPublications() {
        let store = Self.store(count: 20)
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace(1, attention: true), Self.workspace(2, attention: true)])
        #expect(store.attentionCount == 2)
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace(1)])
        #expect(store.attentionCount == 1)
        // Another space's Mac never counts.
        store.workspaces.append(Self.workspace(90, mac: "other"))
        store.updateWorkspaces(macID: "other", rows: [Self.workspace(90, mac: "other", attention: true)])
        #expect(store.attentionCount == 1)
        #expect(store.workspaces.last?.needsAttention == true)
    }

    @Test func rowsAreFoundAfterTheListChangedShape() {
        let store = Self.store(count: 10)
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace(4, title: "a")])
        // A new row at the top moves every index.
        store.workspaces.insert(Self.workspace(77), at: 0)
        store.updateWorkspaces(macID: "m1", rows: [Self.workspace(4, title: "b"), Self.workspace(77, title: "new")])
        #expect(store.workspace(id: "w4")?.title == "b")
        #expect(store.workspace(id: "w77")?.title == "new")
        #expect(store.workspaces.count == 11)
    }

    /// The same id on two Macs: each Mac's row is its own.
    @Test func aRepeatedIDOnAnotherMacIsThatMacsRow() {
        let store = Self.store(count: 3)
        store.workspaces.append(Self.workspace(1, mac: "m2"))
        store.updateWorkspaces(macID: "m2", rows: [Self.workspace(1, mac: "m2", title: "on m2")])
        #expect(store.workspaces[1].title == "Workspace 1")
        #expect(store.workspaces[3].title == "on m2")
    }
}
