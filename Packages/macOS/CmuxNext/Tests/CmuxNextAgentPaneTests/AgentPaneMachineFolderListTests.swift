import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The folder chooser's `machine.folder.list`: a new chat on this Mac lists the folders of the machine its composer picked
/// (named in the request, Leo, 2026-11-23: "start a chat in a picked folder"); a chat on another machine lists its own.
@Suite(.serialized)
@MainActor
struct AgentPaneMachineFolderListTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func ask(_ model: AgentPaneModel, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "machine.folder.list", "params": params]))
    }

    @Test func aLocalChatListsThePickedMachineNotThisMac() async {
        let model = AgentPaneModel(host: NoHost())
        var asked: [(String?, Bool, String?)] = []
        model.onListMachineFolder = { path, files, machine in asked.append((path, files, machine)); return ["path": "/home/dev"] }
        let reply = await ask(model, ["path": "/srv", "machine": "lab-box"])
        #expect((reply["value"] as? [String: Any])?["path"] as? String == "/home/dev", "\(reply)")
        #expect(asked.count == 1 && asked[0].0 == "/srv" && asked[0].2 == "lab-box")
    }

    @Test func aLocalChatNamingNoMachineIsRefusedAndNeverListsThisMac() async {
        let model = AgentPaneModel(host: NoHost())
        model.onListMachineFolder = { _, _, _ in Issue.record("listed with no machine"); return [:] }
        let reply = await ask(model, [:])
        #expect(reply["ok"] as? Bool == false, "\(reply)")
    }

    @Test func aChatOnAnotherMachineListsItsOwnWhenNoMachineIsNamed() async {
        let model = AgentPaneModel(host: NoHost())
        model.remoteChat = true
        var machines: [String?] = []
        model.onListMachineFolder = { _, _, machine in machines.append(machine); return [:] }
        _ = await ask(model, [:])
        #expect(machines == [nil])
    }
}
