import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Two machines can list a chat under one tab id (a forked machine keeps its tab ids). The
/// follow-ups of #36767 (F1–F3): each path below finds its chat on its own machine.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct AgentTabsMachineFollowupTests {
    static func tabs() -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = "install:machine-followup-test"
        tabs.remoteHostScoped = { _ in MockAgentPaneHost() }
        return tabs
    }

    /// F1: the header's "is this chat still shown" check reads the session on the chat's own machine.
    @Test func theHeaderStillShowsItsChatWhenAnotherMachineHasTheSameID() throws {
        let tabs = Self.tabs()
        let tree = DaemonStore()
        tabs.lookupScoped = { key in
            ["a", "b"].contains(key.machine) && key.key == "tab_forked"
                ? (AgentSessionRef(host: "install:machine-\(key.machine)", hostName: key.machine, session: "s-\(key.machine)", harness: "claude"), tree) : nil
        }
        let onA = try #require(tabs.view(for: "tab_forked", machine: "a"))
        _ = try #require(tabs.view(for: "tab_forked", machine: "b"))
        #expect(onA.model.header?.showsChat("s-a") == true, "machine a's chat read as no longer shown")
        #expect(onA.model.header?.showsChat("s-b") == false)
    }

    /// F2: a chat tab's fallback page handler finds its tab on the machine it was asked for. It runs
    /// the app on a same-tree daemon (``AgentChatActionFixture``), so it runs where the lane has one,
    /// as that fixture's other suites do.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aChatsPageHandlerFindsItsTabWhenAnotherMachineHasTheSameID() async throws {
        try await AgentChatActionFixture.withApp { services, _ in
            let tabs = services.agentTabs
            let pane = try #require(services.windows.active?.focusedPane)
            let id = try #require(pane.pane.tabs.first?.id)
            let local = AgentTabKey(machine: services.daemon.machineID, key: id)
            tabs.newTabPages[local] = nil
            tabs.sessions[local] = "s-here"
            tabs.sessions[AgentTabKey(machine: "forked-machine", key: id)] = "s-there"
            #expect(tabs.pageHandler(id, machine: local.machine) != nil, "this Mac's chat lost its page handler to a same-id tab elsewhere")
        }
    }

    /// F3: a second start of a new remote chat joins the running one after the tree dropped the
    /// provisional alias: the start is found through the machine's remote alias.
    @Test func aSecondRemoteStartJoinsTheFirstAfterTheProvisionalAliasGoes() async throws {
        let tabs = Self.tabs()
        let provisional = AgentTabKey(machine: "mini", key: "tab_provisional")
        let pending = AgentTabPending(key: provisional.key, surface: .init(rawValue: 1))
        // task-owner: the creation that never answers in this test; cancelled below.
        pending.result = Task { try await Task.sleep(for: .seconds(600)); throw CancellationError() }
        defer { pending.result?.cancel() }
        tabs.remoteCreations[provisional] = pending
        // task-owner: the first start; cancelled below.
        let first = Task { _ = try await tabs.startRemoteChat(provisional.key, machine: provisional.machine, endpoint: { throw CancellationError() }) }
        defer { first.cancel() }
        await Task.yield()
        tabs.rekey(provisional.key, to: "tab_real", machine: provisional.machine)
        _ = tabs.aliases.removeValue(forKey: provisional) // the settled tree no longer lists the provisional id
        // task-owner: the second start; cancelled below.
        let second = Task { _ = try await tabs.startRemoteChat(provisional.key, machine: provisional.machine, endpoint: { throw CancellationError() }) }
        defer { second.cancel() }
        await Task.yield()
        #expect(tabs.remoteStarts.keys.count == 1, "a second start ran beside the first: \(tabs.remoteStarts.keys)")
    }
}
