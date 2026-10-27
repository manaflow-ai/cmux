@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21, session lineage PR 2: "LIKE E.G. AGENT SESSION CREATION LINEAGES... CLAUDE CODE
/// MOSTLY JUST HAS ONE LAYER... WHAT IF WE DID MORE? OR DIFFERENT?" A session workspace an agent
/// opens (`agent.openSessionWorkspace` with a caller session) records the caller as its lineage
/// parent, so the sidebar's session tree nests it under the caller's workspace even when the
/// session's daemon lists no lineage; the daemon's lineage wins wherever it lists one.
@MainActor @Suite struct AgentSessionLineageTests {
    private static let localHost = "install:mac"
    private static let caller = WorkspaceID("ws-caller")
    private static let opened = WorkspaceID("ws-opened")
    private static let spawner = WorkspaceID("ws-spawner")

    private static func identity(_ host: String = localHost, _ session: String) -> AgentSessionParents.Identity {
        AgentSessionParents.identity(host: host, session: session)
    }

    private static func chats(host: String = localHost) -> [(WorkspaceID, [AgentSessionRef])] {
        [
            (caller, [AgentSessionRef(host: host, session: "s-caller")]),
            (opened, [AgentSessionRef(host: host, session: "s-opened")]),
            (spawner, [AgentSessionRef(host: host, session: "s-spawner")]),
        ]
    }

    private static func lane(_ id: String, spawnedBy: String?) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: .idle, since: nil, error: nil,
                          spawnedBy: spawnedBy)
    }

    @Test func anAgentOpenedSessionWithNoDaemonLineageRecordsItsCallerAsParent() {
        let localParents = AgentSessionParents(defaults: nil)
        AgentSessionWorkspace.recordParent(Self.identity("s-caller"), of: Self.identity("s-opened"), in: localParents)
        #expect(localParents.parents == [Self.identity("s-opened"): Self.identity("s-caller")])
        // A local daemon that lists no lineage (an older acpmux).
        let lanes = ["s-caller": Self.lane("s-caller", spawnedBy: nil), "s-opened": Self.lane("s-opened", spawnedBy: nil)]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: localParents.parents,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents == [Self.opened: Self.caller])
        // A remote daemon that lists none either uses its own host-qualified records.
        let remoteParents = AgentSessionParents(defaults: nil)
        AgentSessionWorkspace.recordParent(Self.identity("registry:vm", "s-caller"),
                                           of: Self.identity("registry:vm", "s-opened"), in: remoteParents)
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:],
                                                 recordedParents: remoteParents.parents,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents == [Self.opened: Self.caller])
    }

    @Test func thePersonsOpenRecordsNothing() {
        let parents = AgentSessionParents(defaults: nil)
        AgentSessionWorkspace.recordParent(nil, of: Self.identity("s-opened"), in: parents)
        AgentSessionWorkspace.recordParent(Self.identity("", "  "), of: Self.identity("s-opened"), in: parents)
        AgentSessionWorkspace.recordParent(Self.identity("s-opened"), of: Self.identity("s-opened"), in: parents)
        #expect(parents.parents.isEmpty)
        let pass = SidebarSessionTreeFeed.pass(Self.chats(), lanes: [:], recordedParents: parents.parents,
                                               localHost: Self.localHost, pullRequests: [:])
        #expect(pass.state.parents.isEmpty)
    }

    @Test func theDaemonsLineageWinsWhenItListsOne() {
        let recorded = [Self.identity("s-opened"): Self.identity("s-caller")]
        // This Mac's acpmux says another session spawned it.
        let lanes = ["s-opened": Self.lane("s-opened", spawnedBy: "s-spawner")]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: recorded,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents == [Self.opened: Self.spawner])
        // Another machine's daemon listed its parent.
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:],
                                                 remoteParentsByHost: ["registry:vm": ["s-opened": "s-spawner"]], recordedParents: recorded,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents == [Self.opened: Self.spawner])
    }

    /// A daemon parent no workspace here shows still wins: the child stays top level rather than
    /// nesting under the recorded caller.
    @Test func aDaemonParentNoWorkspaceShowsStillWins() {
        let recorded = [Self.identity("s-opened"): Self.identity("s-caller")]
        let lanes = ["s-opened": Self.lane("s-opened", spawnedBy: "s-hidden")]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: recorded,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents.isEmpty)
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:],
                                                 remoteParentsByHost: ["registry:vm": ["s-opened": "s-hidden"]], recordedParents: recorded,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents.isEmpty)
    }

    /// A record that would close a loop (a caller recorded under its own descendant) is refused.
    @Test func aRecordThatWouldMakeACycleIsRefused() {
        let parents = AgentSessionParents(defaults: nil)
        parents.record(Self.identity("a"), of: Self.identity("b"))
        parents.record(Self.identity("b"), of: Self.identity("c"))
        parents.record(Self.identity("c"), of: Self.identity("a"))
        parents.record(Self.identity("b"), of: Self.identity("a"))
        #expect(parents.parents == [Self.identity("b"): Self.identity("a"), Self.identity("c"): Self.identity("b")])
    }

    /// A recorded parent that would close a loop with the daemon's lineage is left out: the caller's
    /// workspace stays a root rather than both rows nesting under each other.
    @Test func aRecordedParentNeverLoopsWithTheDaemonsLineage() {
        // Recorded: s-caller's parent is s-opened; the daemon says s-opened was spawned by s-caller.
        let recorded = [Self.identity("s-caller"): Self.identity("s-opened")]
        let lanes = ["s-opened": Self.lane("s-opened", spawnedBy: "s-caller")]
        let pass = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: recorded,
                                               localHost: Self.localHost, pullRequests: [:])
        #expect(pass.state.parents == [Self.opened: Self.caller])
    }

    @Test func recordedParentsSurviveARelaunchAndKeepTheNewest() throws {
        let suite = "cmux.next.tests.lineage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AgentSessionParents(defaults: defaults)
        first.record(Self.identity("s-caller"), of: Self.identity("s-opened"))
        first.record(Self.identity("s-spawner"), of: Self.identity("s-opened"))
        first.record(Self.identity("s-caller"), of: Self.identity("s-other"))
        let relaunched = AgentSessionParents(defaults: defaults)
        #expect(relaunched.parents == [Self.identity("s-opened"): Self.identity("s-spawner"),
                                      Self.identity("s-other"): Self.identity("s-caller")])
    }

    @Test func sameSessionIDOnDifferentHostsResolvesRecordedParentsByHost() {
        let parents = AgentSessionParents(defaults: nil)
        parents.record(Self.identity("registry:a", "same-parent"), of: Self.identity("registry:a", "same-child"))
        parents.record(Self.identity("registry:b", "same-parent"), of: Self.identity("registry:b", "same-child"))
        let aParent = WorkspaceID("ws-a-parent"), aChild = WorkspaceID("ws-a-child")
        let bParent = WorkspaceID("ws-b-parent"), bChild = WorkspaceID("ws-b-child")
        let chats: [(WorkspaceID, [AgentSessionRef])] = [
            (aParent, [AgentSessionRef(host: "registry:a", session: "same-parent")]),
            (aChild, [AgentSessionRef(host: "registry:a", session: "same-child")]),
            (bParent, [AgentSessionRef(host: "registry:b", session: "same-parent")]),
            (bChild, [AgentSessionRef(host: "registry:b", session: "same-child")]),
        ]
        let pass = SidebarSessionTreeFeed.pass(chats, lanes: [:], recordedParents: parents.parents,
                                               localHost: Self.localHost, pullRequests: [:])
        #expect(pass.state.parents[aChild] == aParent)
        #expect(pass.state.parents[bChild] == bParent)
    }

    @Test func sameRemoteSessionIDOnDifferentHostsResolvesDaemonParentsByHost() {
        let aParent = WorkspaceID("ws-remote-a-parent"), aChild = WorkspaceID("ws-remote-a-child")
        let bParent = WorkspaceID("ws-remote-b-parent"), bChild = WorkspaceID("ws-remote-b-child")
        let chats: [(WorkspaceID, [AgentSessionRef])] = [
            (aParent, [AgentSessionRef(host: "registry:a", session: "same-parent")]),
            (aChild, [AgentSessionRef(host: "registry:a", session: "same-child")]),
            (bParent, [AgentSessionRef(host: "registry:b", session: "same-parent")]),
            (bChild, [AgentSessionRef(host: "registry:b", session: "same-child")]),
        ]
        let pass = SidebarSessionTreeFeed.pass(chats, lanes: [:],
                                               remoteParentsByHost: [
                                                   "registry:a": ["same-child": "same-parent"],
                                                   "registry:b": ["same-child": "same-parent"],
                                               ],
                                               localHost: Self.localHost, pullRequests: [:])
        #expect(pass.state.parents[aChild] == aParent)
        #expect(pass.state.parents[bChild] == bParent)
    }

    @Test func aQualifiedRemoteLookupNeverFallsBackToAnotherHost() {
        let links = RemoteAgentSessionLinks()
        links.note([["sessionId": "same-child", "startedBy": "same-parent"]], host: "registry:a")
        #expect(links.parent(of: "same-child", host: "registry:a") == "same-parent")
        #expect(links.parent(of: "same-child", host: "registry:b") == nil)
        #expect(!links.descends("same-child", from: "same-parent", host: "registry:b"))
    }

    @Test func duplicateTabsShareAnIdentityOnlyWhenTheirHostMatches() {
        let sameHost = [AgentSessionRef(host: "registry:a", session: "same"),
                        AgentSessionRef(host: "registry:a", session: "same")]
        #expect(AgentSessionWorkspace.callerIdentity("same", in: sameHost) == Self.identity("registry:a", "same"))
        let twoHosts = sameHost + [AgentSessionRef(host: "registry:b", session: "same")]
        #expect(AgentSessionWorkspace.callerIdentity("same", in: twoHosts) == nil)
    }
}
