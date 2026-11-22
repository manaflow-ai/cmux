@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// cx-rcby: the sidebar filled with empty "New Group" groups. Every New
/// Workspace Group (Ctrl-Cmd-G, the sidebar menu) moved the active
/// workspace into a new group and left the group it came from in the home
/// daemon with no member; the daemon keeps an empty group, so each press
/// added one more. The rule (chief decision): an unpinned group that loses
/// its last live member is removed; New Group on workspaces that already
/// form one whole group makes no second group; a group made with no member
/// goes when its name editor closes while it is still empty.
struct PersonalGroupLifecycleTests {
    typealias Life = PersonalGroupLifecycle
    static let session = "11111111-2222-4333-8444-555555555555"
    static let g1: WorkspaceGroupID = "grp_1"
    static let g2: WorkspaceGroupID = "grp_2"

    static func row(_ key: String, _ group: WorkspaceGroupID?, index: Int = 0) -> PersonalWorkspace {
        PersonalWorkspace(sessionID: session, workspaceKey: WorkspaceKey(rawValue: key), index: index, group: group)
    }

    static func member(_ key: String) -> Life.Member { Life.Member(session: session, key: key) }

    static func groups(pinned: Set<WorkspaceGroupID> = []) -> [Life.Group] {
        [g1, g2].map { Life.Group(id: $0, pinned: pinned.contains($0)) }
    }

    @Test func repeatedNewGroupOnTheSameWorkspaceEmptiesTheGroupItLeaves() {
        // w3 is the only member of g1; New Group moves it to a new group.
        let rows = [Self.row("w1", nil), Self.row("w3", Self.g1)]
        let emptied = Life.emptied(groups: Self.groups(), rows: rows, leaving: [Self.member("w3")], into: nil) { _ in true }
        #expect(emptied == [Self.g1])
    }

    @Test func aGroupThatKeepsAMemberStays() {
        let rows = [Self.row("w1", Self.g1), Self.row("w2", Self.g1)]
        let emptied = Life.emptied(groups: Self.groups(), rows: rows, leaving: [Self.member("w1")], into: nil) { _ in true }
        #expect(emptied.isEmpty)
    }

    @Test func aMoveInsideItsOwnGroupEmptiesNothing() {
        let rows = [Self.row("w1", Self.g1)]
        let emptied = Life.emptied(groups: Self.groups(), rows: rows, leaving: [Self.member("w1")], into: Self.g1) { _ in true }
        #expect(emptied.isEmpty)
    }

    @Test func aPinnedGroupStaysEmpty() {
        let rows = [Self.row("w1", Self.g1)]
        let emptied = Life.emptied(groups: Self.groups(pinned: [Self.g1]), rows: rows, leaving: [Self.member("w1")], into: nil) { _ in true }
        #expect(emptied.isEmpty)
    }

    /// A closed workspace keeps its personal row (reopen restores its
    /// group); it is no member the sidebar shows, so it keeps nothing alive.
    @Test func aClosedWorkspacesRowKeepsNoGroupAlive() {
        let rows = [Self.row("w1", Self.g1), Self.row("closed", Self.g1)]
        let emptied = Life.emptied(groups: Self.groups(), rows: rows, leaving: [Self.member("w1")], into: Self.g2) { $0.key != "closed" }
        #expect(emptied == [Self.g1])
    }

    @Test func movingEveryMemberOfTwoGroupsEmptiesBoth() {
        let rows = [Self.row("a", Self.g1), Self.row("b", Self.g2), Self.row("c", nil)]
        let emptied = Life.emptied(groups: Self.groups(), rows: rows, leaving: [Self.member("a"), Self.member("b")], into: nil) { _ in true }
        #expect(Set(emptied) == [Self.g1, Self.g2])
    }

    @Test func newGroupOnAWholeGroupNamesThatGroup() {
        let rows = [Self.row("w3", Self.g1), Self.row("w4", Self.g2), Self.row("w5", Self.g2)]
        #expect(Life.whole(groups: Self.groups(), rows: rows, members: [Self.member("w3")]) { _ in true } == Self.g1)
        #expect(Life.whole(groups: Self.groups(), rows: rows, members: [Self.member("w4")]) { _ in true } == nil)
        #expect(Life.whole(groups: Self.groups(), rows: rows, members: [Self.member("w4"), Self.member("w5")]) { _ in true } == Self.g2)
        #expect(Life.whole(groups: Self.groups(), rows: rows, members: [Self.member("w3"), Self.member("w4")]) { _ in true } == nil)
        #expect(Life.whole(groups: Self.groups(), rows: rows, members: []) { _ in true } == nil)
    }

    @Test func anExplicitGroupIsEmptyUntilAMemberJoins() {
        #expect(Life.isEmpty(Self.g1, rows: [Self.row("w1", nil)]) { _ in true })
        #expect(!Life.isEmpty(Self.g1, rows: [Self.row("w1", Self.g1)]) { _ in true })
        #expect(Life.isEmpty(Self.g1, rows: [Self.row("closed", Self.g1)]) { $0.key != "closed" })
    }
}
