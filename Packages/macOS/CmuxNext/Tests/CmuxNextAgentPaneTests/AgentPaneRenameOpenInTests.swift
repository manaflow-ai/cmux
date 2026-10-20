import Testing
@testable import CmuxNextAgentPane

/// The header's thread title (`pane.rename {name}`) and Thread details' Open in (`folder.openIn
/// {app?}`), Lucas 2026-10-17. Rename takes a trimmed, bounded name and answers the tab's refusal;
/// Open in names no path (the App uses the tab's own folder) and is refused for a chat of another
/// machine. Neither runs on a New Tab page.
@Suite
@MainActor
struct AgentPaneRenameOpenInTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Calls {
        var names: [String] = []
        var apps: [String?] = []
        var renames = true
    }

    private static func pane(_ calls: Calls, remote: Bool = false) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat")
        model.remoteChat = remote
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() })
        model.header?.rename = { name in
            calls.names.append(name)
            return calls.renames
        }
        model.header?.openIn = { app in
            calls.apps.append(app)
            return [["id": "finder", "name": "Finder"]]
        }
        return model
    }

    private static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func renameTakesATrimmedNameAndAnswersARefusal() async {
        let calls = Calls()
        let model = Self.pane(calls)
        let reply = await model.respond(to: Self.request("pane.rename", ["name": "  Retry uploads  "]))
        #expect(reply["ok"] as? Bool == true)
        #expect(calls.names == ["Retry uploads"])
        calls.renames = false
        let refused = await model.respond(to: Self.request("pane.rename", ["name": "Other"]))
        #expect(refused["ok"] as? Bool == false)
    }

    @Test func renameRefusesAnEmptyOrLongName() async {
        let calls = Calls()
        let model = Self.pane(calls)
        _ = await model.respond(to: Self.request("pane.rename", ["name": "   "]))
        _ = await model.respond(to: Self.request("pane.rename", ["name": String(repeating: "a", count: 257)]))
        #expect(calls.names.isEmpty)
    }

    @Test func openInListsWithoutAnAppAndOpensWithOne() async {
        let calls = Calls()
        let model = Self.pane(calls)
        let listed = await model.respond(to: Self.request("folder.openIn", [:]))
        #expect(listed["ok"] as? Bool == true)
        _ = await model.respond(to: Self.request("folder.openIn", ["app": "vscode"]))
        _ = await model.respond(to: Self.request("folder.openIn", ["app": String(repeating: "x", count: 33)]))
        #expect(calls.apps == [nil, "vscode"])
    }

    @Test func openInIsRefusedForAChatOfAnotherMachine() async {
        let calls = Calls()
        let reply = await Self.pane(calls, remote: true).respond(to: Self.request("folder.openIn", ["app": "finder"]))
        #expect(reply["ok"] as? Bool == false)
        #expect(calls.apps.isEmpty)
    }

}
