@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A browser opened in a workspace with no pane named (`beside_chat`) goes in the column right of that
/// workspace's agent chat, as the chat's own agent's does, never in the chat's pane (Lawrence 2026-11-19: "agent
/// chat that is on left, will open stuff to the right"). The Chief's `<show>` block ran `cmux tab create browser
/// --workspace <the subagent's>`; a workspace's default pane is its chat's pane, so one chat's tab strip held 14
/// pages. A run that names its pane or tab keeps it.
@Suite(.timeLimit(.minutes(1))) struct ScriptedBrowserBesideChatTests {
    /// ``AgentBesideKindPlacementTests/snapshot(right:shown:)`` with `page`, a browser tab a script opened
    /// earlier, in the chat's own pane (selected there when `selected`).
    static func snapshot(right: [ControlPaneInfo], shown: Bool, page: Bool = false, selected: Bool = false) -> ControlSnapshot {
        var snapshot = AgentBesideKindPlacementTests.snapshot(right: right, shown: shown)
        guard page else { return snapshot }
        for w in snapshot.topology.workspaces.indices {
            for s in snapshot.topology.workspaces[w].screens.indices {
                for p in snapshot.topology.workspaces[w].screens[s].panes.indices
                where snapshot.topology.workspaces[w].screens[s].panes[p].id == "pane-chat" {
                    snapshot.topology.workspaces[w].screens[s].panes[p].tabs.append(
                        ControlTabInfo(id: "tab-page", surface: "44", kind: "browser", title: "Pull request"))
                    if selected { snapshot.topology.workspaces[w].screens[s].panes[p].selectedTabID = "tab-page" }
                }
            }
        }
        return snapshot
    }

    /// `action.run openBrowser` at `target` from a caller that is not the chat's agent (the Chief's CLI), which
    /// named only the workspace (`named: false`, `beside_chat`) or that pane itself.
    func request(target: String, in snapshot: ControlSnapshot, named: Bool = false) async throws -> ControlActionRequest {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = snapshot }
        executor.router.withLock { $0 = router }
        var params: [String: JSONValue] = ["action": "openBrowser", "args": ["url": "https://example.com"], "target": .string("tab:" + target)]
        if !named { params["beside_chat"] = true }
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: params)).get()
        return try #require(executor.all.first)
    }

    @Test func aChatWithNoColumnGetsANewColumnNotATabInItsPane() async throws {
        let request = try await request(target: "tab-chat", in: Self.snapshot(right: [], shown: false))
        // The chat's own tab with newColumnBeside: the app moves the new tab into a new column right of the chat.
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-chat"))
        #expect(request.newColumnBeside)
        #expect(request.besideCaller)
    }

    @Test func aShownChatWithAColumnLetsTheAppPlaceTheBrowser() async throws {
        let right = [AgentBesideKindPlacementTests.pane("pane-term", [("tab-term", "terminal")])]
        let request = try await request(target: "tab-chat", in: Self.snapshot(right: right, shown: true))
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-chat"), "\(String(describing: request.target))")
        #expect(request.newColumnBeside)
        #expect(request.besideCaller)
    }

    @Test func anUnshownChatWithAColumnGetsTheTabInThatColumn() async throws {
        let right = [AgentBesideKindPlacementTests.pane("pane-term", [("tab-term", "terminal")]),
                     AgentBesideKindPlacementTests.pane("pane-web", [("tab-web", "browser")])]
        let request = try await request(target: "tab-chat", in: Self.snapshot(right: right, shown: false))
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-web"), "\(String(describing: request.target))")
        #expect(!request.newColumnBeside)
        #expect(request.besideCaller)
    }

    /// The pane's selected tab is a page that landed there before this rule: the pane still holds the chat.
    @Test func aPageSelectedInTheChatsPaneStillOpensBesideTheChat() async throws {
        let right = [AgentBesideKindPlacementTests.pane("pane-web", [("tab-web", "browser")])]
        let request = try await request(target: "tab-page", in: Self.snapshot(right: right, shown: false, page: true, selected: true))
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-web"), "\(String(describing: request.target))")
        #expect(request.besideCaller)
    }

    @Test func aPaneWithNoChatKeepsTheTab() async throws {
        let right = [AgentBesideKindPlacementTests.pane("pane-term", [("tab-term", "terminal")])]
        let request = try await request(target: "tab-term", in: Self.snapshot(right: right, shown: true))
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-term"))
        #expect(!request.newColumnBeside)
        #expect(!request.besideCaller)
    }

    /// `--pane <the chat's>`, and `browser.page.right`, whose reply reads the pane it aimed at.
    @Test func aRunThatNamesTheChatsPaneKeepsIt() async throws {
        let right = [AgentBesideKindPlacementTests.pane("pane-web", [("tab-web", "browser")])]
        let request = try await request(target: "tab-chat", in: Self.snapshot(right: right, shown: true), named: true)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-chat"))
        #expect(!request.newColumnBeside)
        #expect(!request.besideCaller)
    }

    /// `cmux open --workspace WS URL` (`browser.open_split` `workspace_id`): the workspace's default pane is the chat's.
    @Test func openSplitIntoAnAgentsWorkspaceOpensBesideItsChat() async throws {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        let right = [AgentBesideKindPlacementTests.pane("pane-web", [("tab-web", "browser")])]
        router.snapshots.publish { $0 = Self.snapshot(right: right, shown: false) }
        executor.router.withLock { $0 = router }
        let reply = try await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: [
            "url": "https://example.com/", "workspace_id": "ws-agent", "focus": false,
        ])).get()
        let run = try #require(executor.all.first)
        #expect(run.target == ControlTargetRef(kind: "tab", id: "tab-web"), "\(String(describing: run.target))")
        #expect(run.besideCaller)
        #expect(reply["pane_id"] == "pane-web", "\(String(describing: reply["pane_id"]))")
    }
}
