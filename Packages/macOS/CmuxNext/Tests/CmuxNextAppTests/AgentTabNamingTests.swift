import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Agent chat tabs read as their chat (2026-10-20, msg 5944: a Chief subagent's tab read
/// "Agent" with a gray "Chief" badge). The Chief runs its subagents on its own acpmux
/// (`chief:<home id>`), which the app now watches beside its own; a Chief's `<chat>` view and
/// session names are never a title; a tab whose chat has no title yet reads as its workspace's
/// task; and a tree that runs on this Mac wears no machine badge.
@MainActor
@Suite(.serialized)
struct AgentTabNamingTests {
    static let localHost = "install:tab-naming"
    static let chiefHost = "chief:2e448bc2"

    // MARK: Titles

    @Test(arguments: [
        ("Plan a three-dish picnic menu\nwith dessert", "Plan a three-dish picnic menu"),
        ("<chat>\n0+512|user: merge PR\n</chat>Your task:\n\nTitle: ACP agent tab names\nGroup: cmux-next app\nDo it", "ACP agent tab names"),
        ("<chat>\nview\n</chat>\nYour task:\nGroup: Performance\nMake create and close fast", "Make create and close fast"),
        ("<3 this app, make it faster", "<3 this app, make it faster"),
    ])
    func aPromptReadsAsItsGist(prompt: String, gist: String) {
        #expect(AgentTurnStates.promptGist(prompt) == gist)
    }

    @Test func aChatViewCutOffBeforeItClosesIsNoTitle() {
        #expect(AgentTurnStates.promptGist("<chat> 0+512|user: merge cmux PR 17453 (outcome?)…") == nil)
        #expect(AgentTurnStates.promptGist("<chat>") == nil)
    }

    @Test func aChiefSubagentsSessionNameAndChatViewAreNoTitle() {
        var summary: [String: Any] = [
            "sessionId": "c1", "name": "optchat-sub-2e448bc2-a345", "harness": "claude", "family": "claude",
            "title": "<chat>", "lastPrompt": "Not stuck, keep going.", "tags": ["optchat.subagent": "a345"],
        ]
        #expect(AgentTurnStates.title(summary) == nil, "neither the session name, the <chat> view nor a later tell names it")
        summary["title"] = "ACP agent tab names"
        #expect(AgentTurnStates.title(summary) == "ACP agent tab names")
        #expect(AgentTurnStates.title(["sessionId": "u1", "name": "my chat", "harness": "claude"]) == "my chat",
                "a name the user gave still wins")
    }

    @Test func generatedTitleDoesNotTreatPromptFallbackAsGenerated() {
        let prompt = [
            "sessionId": "p1", "name": "claude-1", "harness": "claude",
            "title": "Fix the sidebar drag", "titleSource": "prompt",
        ] as [String: Any]
        #expect(AgentTurnStates.title(prompt, includingPrompt: false) == nil)

        var generated = prompt
        generated["titleSource"] = "generated"
        #expect(AgentTurnStates.title(generated, includingPrompt: false) == "Fix the sidebar drag")

        var renamed = prompt
        renamed["titleSource"] = "named"
        #expect(AgentTurnStates.title(renamed, includingPrompt: false) == nil)
    }

    @Test func anUntitledChatReadsAsItsWorkspacesTask() {
        let turns = AgentTurnStateStore()
        let ref = AgentSessionRef(host: Self.chiefHost, session: "c9", harness: "claude")
        #expect(AgentChatTabTitle.untitled(ref, workspaceName: "a345 · ACP agent tab names", turns: turns) == "ACP agent tab names")
        #expect(AgentChatTabTitle.untitled(ref, workspaceName: "cmux", turns: turns) == "cmux")
        #expect(AgentChatTabTitle.untitled(ref, workspaceName: "  ", turns: turns) == AgentPaneModel.tabTitle)
    }

    // MARK: The Chief's acpmux

    @Test func aChiefSubagentTabReadsItsTitleFromTheChiefsAcpmux() async throws {
        let local = try TaggingAcpmux(sessions: ["s1": [:]], fields: ["s1": ["title": "Local chat"]])
        let chief = try TaggingAcpmux(sessions: ["c1": ["optchat.subagent": "a345"]],
                                      fields: ["c1": ["title": "ACP agent tab names", "name": "optchat-sub-2e448bc2-a345"]])
        let turns = AgentTurnStateStore()
        let localFeed = AgentTurnStateFeed(socketPath: local.path, turns: turns, lanes: AgentLaneStore())
        let chiefFeed = AgentTurnStateFeed(socketPath: chief.path, turns: turns, lanes: AgentLaneStore(), mirroring: Self.chiefHost)
        localFeed.start(localHost: Self.localHost)
        chiefFeed.start(localHost: nil)
        let subagent = AgentSessionRef(host: Self.chiefHost, session: "c1", harness: "claude")
        let mine = AgentSessionRef(host: Self.localHost, session: "s1", harness: "claude")
        try await until { local.watching && chief.watching && turns.title(for: subagent) != nil && turns.title(for: mine) != nil }
        #expect(AgentChatTabTitle.untitled(subagent, turns: turns) == "ACP agent tab names")
        #expect(AgentChatTabTitle.untitled(mine, turns: turns) == "Local chat")
        #expect(turns.localHost == Self.localHost, "the Chief's watch never takes this Mac's host")
        withExtendedLifetime((local, chief, localFeed, chiefFeed)) {}
    }

    @Test func oneWatchsPageLeavesTheOtherWatchsChatsAlone() {
        let turns = AgentTurnStateStore()
        turns.localHost = Self.localHost
        turns.mirroredHosts = [Self.chiefHost]
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: ["c1": "ACP agent tab names"], details: [:],
                      source: Self.chiefHost)
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: ["s1": "Local chat"], details: [:])
        let subagent = AgentSessionRef(host: Self.chiefHost, session: "c1")
        #expect(turns.title(for: subagent) == "ACP agent tab names", "the app's own page must not clear the Chief's chats")
        turns.clearLive()
        #expect(turns.title(for: subagent) == "ACP agent tab names")
    }

    // MARK: Machine badge

    @Test func aTreeOnThisMacWearsNoMachineBadgeAndAPairedServerDoes() throws {
        let registry = MachineRegistry(local: DaemonService())
        let chief = try ServerReach.localChief(homeID: "2e448bc2", socket: "/tmp/cmux-tab-naming-chief.sock", name: "Chief")
        let paired = try ServerReach(hostID: "host_tabnaming01", installID: "inst_tabnaming01", name: "Mac mini",
                                     route: .overlay(linkSocket: "/tmp/cmux-tab-naming-link.sock"))
        for reach in [chief, paired] {
            registry.add(ServerMachineSession(reach: reach, binary: nil, paths: .init(root: URL(fileURLWithPath: "/tmp/cmux-tab-naming-unused")),
                                              environment: { [:] }, localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        }
        #expect(registry.tabBadge(chief.machineID) == nil, "the Chief's subagents run on this Mac")
        #expect(registry.tabBadge(paired.machineID) == "Mac mini")
    }

    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
