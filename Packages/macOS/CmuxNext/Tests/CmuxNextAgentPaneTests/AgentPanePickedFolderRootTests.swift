import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// hq#2569 item 1 at the pane's folder check: a project the person picks from the New Tab folder
/// menu (`workspace.useFolder`) is a folder the pane may use from then on, so the chat's start
/// (`session/new {cwd}`) passes the relay without spending the Send's gesture, which the chat's
/// first prompt needs. Before, the pick granted nothing and the start failed with "This folder is
/// outside the folders this pane may use." whenever the Send's gesture was gone or spent.
@Suite(.serialized)
@MainActor
struct AgentPanePickedFolderRootTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A project folder outside every root of the pane (a fresh, folderless workspace).
    private func makeProject() throws -> (folder: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("hq2569-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("parity-demo").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return (AcpmuxPathPolicy.canonical(folder) ?? folder, { try? FileManager.default.removeItem(at: base) })
    }

    /// Whether the chat's start in `folder` passes the relay's folder check now
    /// (AgentPaneTransport.checkPathsInScope), and the gesture-only roots it would spend.
    private func startPasses(_ model: AgentPaneModel, in folder: String) async -> (passes: Bool, needsGesture: Bool) {
        let transport = model.transport
        let scope = AcpmuxPathPolicy.Scope(roots: transport.roots(), gestureRoots: transport.gestureRoots(),
                                           fillCwd: transport.primaryRoot(), agentHome: transport.agentHome(),
                                           home: transport.homeFolder, granted: transport.addedRoots)
        let start = #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"\#(folder)","mcpServers":[]}}"#
        if case .success(let checked) = await AcpmuxPathPolicy.check(start, scope: scope) {
            return (true, !checked.gestureRootsUsed.isEmpty)
        }
        return (false, false)
    }

    private func status(_ reply: [String: Any]) -> String? { (reply["value"] as? [String: Any])?["status"] as? String }

    /// The person's pick (a click in the pane) makes the folder a root, on the daemon's store
    /// answer (`seed`) and on the compatibility path alike.
    @Test(arguments: [false, true])
    func aProjectThePersonPicksIsAFolderThePaneMayUse(storeAnswers: Bool) async throws {
        let (folder, cleanup) = try makeProject()
        defer { cleanup() }
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        if storeAnswers {
            model.startFolders.resolve = { proposed in
                AgentPaneStartFolder(kind: .seed, cwd: proposed, agentHome: nil)
            }
        }
        #expect(await startPasses(model, in: folder).passes == false, "before the pick the folder is no root")

        model.transport.gestures.record(click: true) // the click on parity-demo in the folder menu
        let reply = await model.respond(to: .useFolder(folder, confirm: false))
        #expect(status(reply) == "ok")

        let start = await startPasses(model, in: folder)
        #expect(start.passes, "the picked folder is refused: transport.path_outside_roots")
        #expect(!start.needsGesture, "the start must not need the Send's gesture: the first prompt spends it")
        #expect(model.transport.addedRoots == [folder])
    }

    /// A page script's `workspace.useFolder` with no person behind it widens nothing: the folder
    /// stays outside until the person acts.
    @Test func aPickWithoutThePersonGrantsNothing() async throws {
        let (folder, cleanup) = try makeProject()
        defer { cleanup() }
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.transport.homeFolder = "/nonexistent-home-\(UUID().uuidString)"
        let reply = await model.respond(to: .useFolder(folder, confirm: false))
        #expect(status(reply) == "ok")
        #expect(model.transport.addedRoots.isEmpty)
        #expect(await startPasses(model, in: folder).passes == false)
    }

    /// The home folder stays the answer to the home question: a plain pick of it grants nothing.
    @Test func pickingTheHomeFolderStillAsksFirst() async throws {
        let (folder, cleanup) = try makeProject()
        defer { cleanup() }
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.transport.homeFolder = folder
        model.transport.gestures.record(click: true)
        let reply = await model.respond(to: .useFolder(folder, confirm: false))
        #expect(status(reply) == "confirm")
        #expect(model.transport.addedRoots.isEmpty)
    }
}
