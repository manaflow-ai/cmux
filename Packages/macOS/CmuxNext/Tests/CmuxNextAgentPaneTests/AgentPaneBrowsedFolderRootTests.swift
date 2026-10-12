import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-nkyvn at the pane's folder check: a folder the user picked in the native Open panel (New Tab
/// > Add project > Local folder, `project.browse`) is the page's project from then on, so its
/// requests about it (the folder's own harnesses, `_acpmux/harnesses {cwd}`) pass the folder check,
/// also for a folder the project scan never lists (one under `~/.cache`).
@Suite(.serialized)
@MainActor
struct AgentPaneBrowsedFolderRootTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aFolderPickedInTheOpenPanelIsTheProjectsRoot() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nkyvn-\(UUID().uuidString)/.cache/repo").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (folder as NSString).deletingLastPathComponent) }
        let model = AgentPaneModel(host: NoHost())
        model.onBrowseProject = { folder }
        let harnesses = #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/harnesses","params":{"cwd":"\#(folder)"}}"#
        func check() async -> Bool {
            // The scope the relay checks a frame against (AgentPaneTransport.checkPathsInScope).
            let transport = model.transport
            let scope = AcpmuxPathPolicy.Scope(roots: transport.roots(), gestureRoots: transport.gestureRoots(),
                                               fillCwd: transport.primaryRoot(), agentHome: transport.agentHome(),
                                               home: transport.homeFolder, granted: transport.addedRoots)
            if case .success = await AcpmuxPathPolicy.check(harnesses, scope: scope) { return true }
            return false
        }
        #expect(await check() == false, "before the pick the folder is no root")

        let reply = await model.respond(to: .browseProject)
        #expect((reply["value"] as? [String: Any])?["cwd"] as? String == folder)
        #expect(await check(), "the picked folder's harnesses are refused (transport.path_outside_roots)")
    }
}
