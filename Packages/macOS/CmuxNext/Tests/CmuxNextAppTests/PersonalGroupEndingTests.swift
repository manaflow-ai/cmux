import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// cx-rcby, the app side of the group lifecycle rule: which personal rows
/// count as live members (a closed workspace's row does not; a session this
/// app cannot see does, so no group goes on a guess), and the sidebar hides
/// a group that is being deleted for losing its last member, so it never
/// flashes back between the move and the delete. Windows are never put on
/// screen.
@MainActor
struct PersonalGroupEndingTests {
    static let keys = (1...3).map { WorkspaceKey(rawValue: "4d5e6f70-8a9b-4cad-8e0f-1a2b3c4d5e7\($0)") }
    nonisolated static let session = "44444444-5555-4666-8777-888888888888"
    static let empty: WorkspaceGroupID = "grp_empty"
    static let full: WorkspaceGroupID = "grp_full"

    /// w1, w2 live; G "full" holds w2 and a closed workspace's row; G "empty" holds nothing.
    private static func services(mixed: Bool) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let live = keys.prefix(2).enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)")
        }
        var tree = DaemonTree(registryID: session, workspaceRevision: 100, workspaces: Array(live))
        tree.personal = PersonalState(
            revision: 1,
            profiles: [ProfileSnapshot(id: .defaultProfile, name: "default", index: 0, follows: [session])],
            groups: [WorkspaceGroupSnapshot(id: empty, name: "Empty", index: 0), WorkspaceGroupSnapshot(id: full, name: "Full", index: 1)],
            workspaces: [
                PersonalWorkspace(sessionID: session, workspaceKey: keys[0], index: 0),
                PersonalWorkspace(sessionID: session, workspaceKey: keys[1], index: 1, group: full),
                // A closed workspace keeps its row (reopen restores its group).
                PersonalWorkspace(sessionID: session, workspaceKey: keys[2], index: 2, group: full),
            ])
        if mixed {
            services.daemon.store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapabilities.shared.personalMixedOrder], generation: "g1"))
        }
        services.daemon.store.apply(snapshot: tree)
        return services
    }

    private static func groupNames(_ services: AppServices) -> [String] {
        PersonalSidebar.sections(of: services.machines.local, room: .defaultProfile, machines: services.machines).compactMap(\.group?.name)
    }

    @Test(arguments: [true, false])
    func anEndingGroupHidesOnlyWhileItShowsNoMember(mixed: Bool) {
        let services = Self.services(mixed: mixed)
        #expect(Self.groupNames(services) == ["Empty", "Full"], "an empty group shows on the home session")
        let personal = services.machines.local.store.personal
        personal.endingGroups = [Self.empty, Self.full]
        #expect(Self.groupNames(services) == ["Full"], "the empty ending group hides; the one with a member stays")
        personal.endingGroups = []
        #expect(Self.groupNames(services) == ["Empty", "Full"])
    }

    @Test func liveMembersAreRowsTheTreeShowsOrCannotJudge() {
        let services = Self.services(mixed: true)
        let life = PersonalGroupLife(machines: services.machines)
        #expect(life.isLive(.init(session: Self.session, key: Self.keys[1].rawValue)))
        #expect(!life.isLive(.init(session: Self.session, key: Self.keys[2].rawValue)), "a closed workspace's row")
        #expect(life.isLive(.init(session: "99999999-0000-4000-8000-000000000000", key: "elsewhere")), "a session this app cannot see")
    }

    @Test func movingTheLastLiveMemberEndsTheGroupDespiteAClosedRow() {
        let services = Self.services(mixed: true)
        let life = PersonalGroupLife(machines: services.machines)
        let w2 = PersonalSidebarPlanner.Placement(session: Self.session, key: Self.keys[1], resource: nil)
        #expect(life.emptied(by: [w2], into: nil) == [Self.full])
        #expect(life.emptied(by: [w2], into: Self.full).isEmpty, "a move inside its own group")
        #expect(life.whole([w2]) == Self.full)
        #expect(life.isEmptyUnpinned(Self.empty))
        #expect(!life.isEmptyUnpinned(Self.full))
    }
}
