#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing

/// The Feed's "Working now" strip lists the agents that work right now, and only those.
@Suite struct FeedWorkingNowTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private static func workspace(_ id: String, mac: String = "mac", title: String? = nil, _ tabs: [WorkspaceTab]) -> Workspace {
        Workspace(id: id, macID: mac, title: title ?? id, directory: "~", tabs: tabs, lastActivityAt: t0)
    }

    private static func agent(_ id: String, _ status: WorkspaceTab.AgentStatus?, kind: WorkspaceTab.Kind = .agent, harness: String? = "claude",
                              title: String = "Claude", subtitle: String? = nil, since: TimeInterval? = nil) -> WorkspaceTab {
        var tab = WorkspaceTab(id: id, kind: kind, title: title, subtitle: subtitle, harness: harness, agentStatus: status)
        tab.workingSince = since.map { t0.addingTimeInterval($0) }
        return tab
    }

    @Test func onlyWorkingAgentTabsAreListed() {
        let agents = WorkingAgent.list(in: [
            Self.workspace("a", [
                Self.agent("working", .working),
                Self.agent("waiting", .waiting),
                Self.agent("idle", nil),
                WorkspaceTab(id: "shell", kind: .terminal, title: "zsh"),
                WorkspaceTab(id: "page", kind: .browser, title: "Docs"),
            ]),
        ])
        #expect(agents.map(\.tabID) == ["working"])
    }

    @Test func aTerminalAgentOpensItsTerminalAndAChatAgentItsChat() {
        let agents = WorkingAgent.list(in: [
            Self.workspace("a", [
                Self.agent("chat", .working, harness: "codex", title: "Codex"),
                Self.agent("term", .working, kind: .terminal, title: "claude"),
            ]),
        ])
        #expect(agents.first { $0.tabID == "chat" }?.opensTerminal == false)
        #expect(agents.first { $0.tabID == "chat" }?.agentName == "Codex")
        #expect(agents.first { $0.tabID == "term" }?.opensTerminal == true)
    }

    @Test func thePlaceIsTheWorkspaceThenWhatTheTabWorksOn() {
        let agents = WorkingAgent.list(in: [
            Self.workspace("a", title: "cmux.com", [Self.agent("t1", .working, subtitle: "Fix pricing page layout")]),
            Self.workspace("b", title: "fleet", [Self.agent("t2", .working)]),
        ])
        #expect(agents.first { $0.tabID == "t1" }?.place == "cmux.com › Fix pricing page layout")
        // A tab that says no more than its agent's name: the workspace alone.
        #expect(agents.first { $0.tabID == "t2" }?.place == "fleet")
    }

    @Test func newestStartFirstAndNoStartTimeLastWhateverTheWorkspaceOrder() {
        let a = Self.workspace("a", [Self.agent("old", .working, since: -600), Self.agent("unknown", .working)])
        let b = Self.workspace("b", [Self.agent("new", .working, since: -30)])
        #expect(WorkingAgent.list(in: [a, b]).map(\.tabID) == ["new", "old", "unknown"])
        #expect(WorkingAgent.list(in: [b, a]).map(\.tabID) == ["new", "old", "unknown"])
        #expect(WorkingAgent.list(in: [a, b]).first?.since == Self.t0.addingTimeInterval(-30))
    }

    @Test func mutedWorkspacesAndOfflineMacsAreNotWorkingNow() {
        let workspaces = [
            Self.workspace("live", mac: "awake", [Self.agent("t1", .working)]),
            Self.workspace("muted", mac: "awake", [Self.agent("t2", .working)]),
            Self.workspace("asleep", mac: "asleep", [Self.agent("t3", .working)]),
        ]
        #expect(WorkingAgent.list(in: workspaces, offlineMacs: ["asleep"], muted: ["muted"]).map(\.tabID) == ["t1"])
        #expect(WorkingAgent.list(in: workspaces).count == 3)
    }

    @Test func nothingWorkingListsNothing() {
        #expect(WorkingAgent.list(in: [Self.workspace("a", [Self.agent("t", .waiting), Self.agent("u", nil)])]).isEmpty)
    }
}
#endif
