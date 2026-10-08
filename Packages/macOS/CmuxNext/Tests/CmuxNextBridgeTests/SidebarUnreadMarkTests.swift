import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextBridge

/// A workspace marked unread by hand (`notification-mark-unread-v1`) shows
/// the unread dot; notification markers still show their count.
@MainActor
struct SidebarUnreadMarkTests {
    static func store(markingUnread names: Set<String>) throws -> DaemonStore {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        var tree = try JSONDecoder().decode(BridgeFixture.Envelope.self, from: Data(contentsOf: url)).data
        for index in tree.workspaces.indices where names.contains(tree.workspaces[index].name) {
            tree.workspaces[index].markedUnread = true
        }
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }

    static let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)

    @Test func aMarkedWorkspaceWithoutNotificationsShowsTheDot() throws {
        let store = try Self.store(markingUnread: ["gamma"])
        let rows = SidebarMapping.shared.sections(store.sidebarSections, machine: Self.machine)[0].workspaces
        #expect(rows.first { $0.title == "gamma" }?.unread == .dot)
    }

    @Test func notificationCountsWinOverTheMark() throws {
        let store = try Self.store(markingUnread: ["beta"])
        let rows = SidebarMapping.shared.sections(store.sidebarSections, machine: Self.machine)[0].workspaces
        #expect(rows.first { $0.title == "beta" }?.unread == .count(1))
    }

    @Test func hiddenSidebarBadgesHideTheMarkToo() throws {
        let store = try Self.store(markingUnread: ["gamma"])
        let gamma = try #require(store.workspaces.first { $0.name == "gamma" })
        #expect(gamma.markedUnread)
        #expect(SidebarMapping.shared.row(gamma, machine: .local, showsUnread: false).unread == .none)
        #expect(SidebarMapping.shared.row(gamma, machine: .local).unread == .dot)
    }
}
