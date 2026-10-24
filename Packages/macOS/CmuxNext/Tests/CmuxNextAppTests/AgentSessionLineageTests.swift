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
        let parents = AgentSessionParents(defaults: nil)
        AgentSessionWorkspace.recordParent("s-caller", of: "s-opened", in: parents)
        #expect(parents.parents == ["s-opened": "s-caller"])
        // A local daemon that lists no lineage (an older acpmux).
        let lanes = ["s-caller": Self.lane("s-caller", spawnedBy: nil), "s-opened": Self.lane("s-opened", spawnedBy: nil)]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: parents.parents,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents == [Self.opened: Self.caller])
        // A remote daemon that lists none either.
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:], recordedParents: parents.parents,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents == [Self.opened: Self.caller])
    }

    @Test func thePersonsOpenRecordsNothing() {
        let parents = AgentSessionParents(defaults: nil)
        AgentSessionWorkspace.recordParent(nil, of: "s-opened", in: parents)
        AgentSessionWorkspace.recordParent("  ", of: "s-opened", in: parents)
        AgentSessionWorkspace.recordParent("s-opened", of: "s-opened", in: parents)
        #expect(parents.parents.isEmpty)
        let pass = SidebarSessionTreeFeed.pass(Self.chats(), lanes: [:], recordedParents: parents.parents,
                                               localHost: Self.localHost, pullRequests: [:])
        #expect(pass.state.parents.isEmpty)
    }

    @Test func theDaemonsLineageWinsWhenItListsOne() {
        let recorded = ["s-opened": "s-caller"]
        // This Mac's acpmux says another session spawned it.
        let lanes = ["s-opened": Self.lane("s-opened", spawnedBy: "s-spawner")]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: recorded,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents == [Self.opened: Self.spawner])
        // Another machine's daemon listed its parent.
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:],
                                                 remoteParents: ["s-opened": "s-spawner"], recordedParents: recorded,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents == [Self.opened: Self.spawner])
    }

    /// A daemon parent no workspace here shows still wins: the child stays top level rather than
    /// nesting under the recorded caller.
    @Test func aDaemonParentNoWorkspaceShowsStillWins() {
        let recorded = ["s-opened": "s-caller"]
        let lanes = ["s-opened": Self.lane("s-opened", spawnedBy: "s-hidden")]
        let local = SidebarSessionTreeFeed.pass(Self.chats(), lanes: lanes, recordedParents: recorded,
                                                localHost: Self.localHost, pullRequests: [:])
        #expect(local.state.parents.isEmpty)
        let remote = SidebarSessionTreeFeed.pass(Self.chats(host: "registry:vm"), lanes: [:],
                                                 remoteParents: ["s-opened": "s-hidden"], recordedParents: recorded,
                                                 localHost: Self.localHost, pullRequests: [:])
        #expect(remote.state.parents.isEmpty)
    }

    /// A record that would close a loop (a caller recorded under its own descendant) is refused.
    @Test func aRecordThatWouldMakeACycleIsRefused() {
        let parents = AgentSessionParents(defaults: nil)
        parents.record("a", of: "b")
        parents.record("b", of: "c")
        parents.record("c", of: "a")
        parents.record("b", of: "a")
        #expect(parents.parents == ["b": "a", "c": "b"])
    }

    /// A recorded parent that would close a loop with the daemon's lineage is left out: the caller's
    /// workspace stays a root rather than both rows nesting under each other.
    @Test func aRecordedParentNeverLoopsWithTheDaemonsLineage() {
        // Recorded: s-caller's parent is s-opened; the daemon says s-opened was spawned by s-caller.
        let recorded = ["s-caller": "s-opened"]
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
        first.record("s-caller", of: "s-opened")
        first.record("s-spawner", of: "s-opened")
        first.record("s-caller", of: "s-other")
        let relaunched = AgentSessionParents(defaults: defaults)
        #expect(relaunched.parents == ["s-opened": "s-spawner", "s-other": "s-caller"])
    }
}
