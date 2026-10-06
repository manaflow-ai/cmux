import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chat header's tools and "..." menu: `pane.action` runs only the listed tab actions, on a
/// chat (never the new tab page), and `pane.tabState` reads the tab's pin.
@MainActor
@Suite struct AgentPaneHeaderActionTests {
    private static func request(_ method: String, _ params: [String: Any] = [:]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
    }

    @Test func theRequestCarriesTheActionAndAnAbsoluteFolder() {
        #expect(Self.request("pane.action", ["id": "splitRight", "cwd": "/tmp/repo"]) == .paneAction("splitRight", cwd: "/tmp/repo"))
        #expect(Self.request("pane.action", ["id": "splitRight", "cwd": "relative"]) == .paneAction("splitRight", cwd: nil))
        #expect(Self.request("pane.action", ["id": "renameTab"]) == .paneAction("renameTab", cwd: nil))
        #expect(Self.request("pane.action", [:]) == .unsupported("pane.action"))
        #expect(Self.request("pane.tabState") == .tabState)
        #expect(AgentPageOps.method(for: "cmux.agent.pane.action") == "pane.action")
        #expect(AgentPageOps.method(for: "cmux.agent.pane.tabState") == "pane.tabState")
    }

    @Test func onlyListedActionsRun() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var ran: [String] = []
        model.onPaneAction = { id, cwd in ran.append("\(id)@\(cwd ?? "")") }
        var reply = await model.respond(to: .paneAction("splitRight", cwd: "/tmp/repo"))
        #expect(reply["ok"] as? Bool == true)
        reply = await model.respond(to: .paneAction("closeAllWindows"))
        #expect(reply["ok"] as? Bool == false)
        reply = await model.respond(to: .paneAction("palette.toggleTabPin"))
        #expect(reply["ok"] as? Bool == true)
        #expect(ran == ["splitRight@/tmp/repo", "palette.toggleTabPin@"])
    }

    @Test func theTabStateComesFromTheApp() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var reply = await model.respond(to: .tabState)
        #expect(reply["ok"] as? Bool == false)
        model.onTabState = { ["pinned": true] }
        reply = await model.respond(to: .tabState)
        #expect((reply["value"] as? [String: Any])?["pinned"] as? Bool == true)
    }
}
