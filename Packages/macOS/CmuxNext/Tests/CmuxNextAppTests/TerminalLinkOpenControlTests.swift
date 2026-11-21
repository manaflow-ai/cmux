import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// `browser.open_link` with a `terminal_id` (#29224): a named terminal that no tab shows refuses
/// a cmux target and opens nothing, so the link never lands in whichever pane has focus; with no
/// `terminal_id` the link still opens from the focused pane.
@MainActor @Suite(.serialized) struct TerminalLinkOpenControlTests {
    private func router(_ services: AppServices) -> ControlRouter {
        _ = NSApplication.shared
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(TerminalLinkOpenControl.methods(services: services))
        return router
    }

    /// Runs `body` with the shared router's cmux opener recording each open (url, source) instead.
    /// The services come first: making them routes `LinkRouter.shared` to them, which the
    /// recorder then replaces; every closure is put back after.
    private func recordingOpens(_ body: (ControlRouter) async throws -> Void) async throws -> [(URL, String?)] {
        let links = LinkRouter.shared
        let saved = (links.routing, links.openInCmux, links.appLink, links.sourceTab, links.textEditor)
        defer { (links.routing, links.openInCmux, links.appLink, links.sourceTab, links.textEditor) = saved }
        let services = AppServices(environment: AppEnvironment.current([:]))
        var opened: [(URL, String?)] = []
        links.routing = { .fallback }
        links.appLink = { _, _ in false }
        links.openInCmux = { url, _, source in opened.append((url, source)) }
        try await body(router(services))
        return opened
    }

    private func openLink(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "browser.open_link", params: params))
    }

    @Test func aTerminalNoTabShowsIsRefusedAndOpensNothing() async throws {
        let opened = try await recordingOpens { router in
            for target: JSONValue? in [nil, "cmux"] {
                var params: [String: JSONValue] = ["url": "https://login.example.test/device", "terminal_id": "term_gone"]
                params["target"] = target
                let result = await openLink(router, params)
                guard case .failure(let error) = result else {
                    Issue.record("expected not_found, got \(result)")
                    continue
                }
                #expect(error.code == "not_found", "\(error)")
                #expect(!error.message.contains("example.test"), "the URL never goes in an error")
            }
        }
        #expect(opened.isEmpty)
    }

    @Test func aTerminalIDThatIsNotAStringIsInvalid() async throws {
        let opened = try await recordingOpens { router in
            let result = await openLink(router, ["url": "https://login.example.test/", "terminal_id": .number(7), "target": "cmux"])
            guard case .failure(let error) = result else {
                Issue.record("expected invalid_params, got \(result)")
                return
            }
            #expect(error.code == "invalid_params", "\(error)")
        }
        #expect(opened.isEmpty)
    }

    @Test func noTerminalIDStillOpensFromTheFocusedPane() async throws {
        let opened = try await recordingOpens { router in
            let reply = try await openLink(router, ["url": "https://login.example.test/", "target": "cmux"]).get()
            #expect(reply["opened_in"]?.stringValue == "cmux", "\(reply)")
        }
        #expect(opened.count == 1)
        #expect(opened.first?.0.absoluteString == "https://login.example.test/")
        #expect(opened.first?.1 == nil)
    }

    /// The agent's chat (`agent-a`) in its own workspace, while the person looks at Home.
    private func agentTopology() -> ControlSnapshot {
        var snapshot = ControlSnapshot()
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        let right = ControlPaneInfo(id: "pane-right", handle: "9", selectedTabID: "tab-right",
                                    tabs: [ControlTabInfo(id: "tab-right", surface: "32", kind: "browser", title: "Docs")])
        var home = ControlWorkspaceInfo(id: "home-key", handle: "10", name: "Home", screens: [ControlScreenInfo(id: "screen-home", handle: "11", panes: [right])])
        home.kind = "home"
        var chat = ControlTabInfo(id: "tab-chat", surface: "41", kind: "conversation", title: "Agent")
        chat.agentSessionID = "agent-a"
        let pane = ControlPaneInfo(id: "pane-agent", handle: "12", selectedTabID: "tab-chat", tabs: [chat])
        let agent = ControlWorkspaceInfo(id: "2487aed7-ede0-435b-85be-ea666881e9ad", handle: "14", name: "Agent work",
                                         screens: [ControlScreenInfo(id: "screen-agent", handle: "13", panes: [pane])])
        topology.workspaces = [home, agent]
        topology.focus = ControlFocus(windowID: "win-1", workspaceID: "home-key", paneID: "pane-right", tabID: "tab-right")
        snapshot.topology = topology
        return snapshot
    }

    /// An agent's `BROWSER` / `open https://…` (no terminal: it runs in an agent chat) opens beside
    /// its own chat, never beside the focused pane in Home (user, 2026-11-18).
    @Test func anAgentsLinkOpensBesideItsOwnChatNotTheFocusedPane() async throws {
        let snapshot = agentTopology()
        let opened = try await recordingOpens { router in
            router.snapshots.publish { $0 = snapshot }
            let reply = try await openLink(router, ["url": "https://github.com/manaflow-ai/cmux/pull/1", "target": "cmux",
                                                    "caller": ["agent_session": "agent-a"]]).get()
            #expect(reply["opened_in"]?.stringValue == "cmux", "\(reply)")
        }
        #expect(opened.count == 1)
        #expect(opened.first?.1 == "tab-chat", "beside the agent's chat: \(String(describing: opened.first?.1))")
    }

    /// An agent whose chat tab is closed opens its link in the workspace its session runs in.
    @Test func anAgentWithAClosedChatOpensItsLinkInItsOwnWorkspace() async throws {
        let snapshot = agentTopology()
        let opened = try await recordingOpens { router in
            router.snapshots.publish { $0 = snapshot }
            _ = try await openLink(router, ["url": "https://github.com/manaflow-ai/cmux/pull/1", "target": "cmux",
                                            "caller": ["agent_session": "agent-gone", "workspace": "2487AED7-EDE0-435B-85BE-EA666881E9AD"]]).get()
        }
        #expect(opened.first?.1 == "tab-chat", "\(String(describing: opened.first?.1))")
    }

    /// An agent cmux cannot place is refused (its shim then uses the default browser); the link
    /// never opens beside the focused pane.
    @Test func anAgentCmuxCannotPlaceIsRefused() async throws {
        let snapshot = agentTopology()
        let opened = try await recordingOpens { router in
            router.snapshots.publish { $0 = snapshot }
            let result = await openLink(router, ["url": "https://login.example.test/", "target": "cmux",
                                                 "caller": ["agent_session": "agent-gone"]])
            guard case .failure(let error) = result else {
                Issue.record("expected caller_unavailable, got \(result)")
                return
            }
            #expect(error.code == "caller_unavailable", "\(error)")
            #expect(!error.message.contains("example.test"), "the URL never goes in an error")
        }
        #expect(opened.isEmpty)
    }
}
