import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The chat folder's actions from the page (the "..." menu's Folder ▸, Session Info, the changed-files card):
/// Open in Editor and Open In ▸ take an editor id of the table, no other action takes an `app`, and a run spends
/// the person's gesture. `editors.list` names the installed editors; `file.open where: finder` reveals a file.
@MainActor
struct AgentPaneEditorRequestTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func run(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "action.run", "params": params])
    }

    @Test func anEditorIDIsDecodedOnlyForTheEditorActions() {
        #expect(Self.run(["id": "agentPane.openCwdInApp", "app": "vscode"]) == .runAction("agentPane.openCwdInApp", app: "vscode"))
        #expect(Self.run(["id": "agentPane.openCwdInEditor", "app": "rustrover", "session": "chat-a"])
            == .runAction("agentPane.openCwdInEditor", session: "chat-a", app: "rustrover"))
        #expect(Self.run(["id": "agentPane.openCwdInEditor"]) == .runAction("agentPane.openCwdInEditor"))
        // Another action never takes an `app`: refused, never dropped.
        for id in ["agentPane.revealCwdInFinder", "agentPane.copyCwdPath", "newCloudMachine", "palette.terminalOpenDirectory"] {
            #expect(Self.run(["id": id, "app": "vscode"]) == .unsupported("action.run"), "\(id)")
        }
    }

    @Test func anAppThatIsNoEditorIDIsRefused() {
        let bad: [Any] = ["", "VSCode", "com.microsoft.VSCode", "/Applications/Zed.app", "zed app", String(repeating: "a", count: 33), "ü", 7, true]
        for value in bad {
            #expect(Self.run(["id": "agentPane.openCwdInApp", "app": value]) == .unsupported("action.run"), "\(value)")
        }
        #expect(AgentPaneRequest.isEditorID("intellij"))
        #expect(AgentPaneRequest.isEditorID("a-1"))
        #expect(AgentPaneRequest.isEditorID(String(repeating: "a", count: 32)))
    }

    @Test func aFolderActionRunsOnAGestureWithItsApp() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return .ran }
        #expect(await model.respond(to: .runAction("agentPane.openCwdInApp", app: "zed"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no editor")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("agentPane.openCwdInApp", app: "zed"))["ok"] as? Bool == true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("agentPane.copyCwdPath"))["ok"] as? Bool == true)
        #expect(ran == ["agentPane.openCwdInApp", "agentPane.copyCwdPath"])
        #expect(arguments == [["app": "zed"], [:]])
    }

    @Test func everyFolderActionIsOnThePagesList() {
        for id in ["agentPane.openCwdInEditor", "agentPane.openCwdInApp", "agentPane.revealCwdInFinder", "agentPane.openCwdInTerminal", "agentPane.copyCwdPath"] {
            #expect(AgentPaneModel.folderActions.contains(id), "\(id)")
        }
        #expect(AgentPaneModel.editorActions.isSubset(of: AgentPaneModel.folderActions))
    }

    @Test func editorsListAnswersWhatTheAppLists() async {
        #expect(AgentPaneRequest(body: ["method": "editors.list"]) == .editorsList)
        let model = AgentPaneModel(host: NoHost())
        #expect(await model.respond(to: .editorsList)["ok"] as? Bool != true, "no host, no list")
        model.onEditorsList = { ["default": ["id": "zed", "name": "Zed"], "others": [["id": "vscode", "name": "Visual Studio Code"]]] }
        let reply = await model.respond(to: .editorsList)
        #expect(reply["ok"] as? Bool == true)
        let value = reply["value"] as? [String: Any]
        #expect((value?["default"] as? [String: String])?["id"] == "zed")
        #expect((value?["others"] as? [[String: String]])?.map { $0["id"] } == ["vscode"])
    }

    @Test func fileOpenDecodesFinder() {
        #expect(AgentPaneRequest(body: ["method": "file.open", "params": ["path": "/tmp/a.swift", "where": "finder"]])
            == .openFile(path: "/tmp/a.swift", target: .finder))
        #expect(AgentPaneRequest(body: ["method": "file.open", "params": ["path": "/tmp/a.swift", "where": "dock"]])
            == .unsupported("file.open"))
    }
}
