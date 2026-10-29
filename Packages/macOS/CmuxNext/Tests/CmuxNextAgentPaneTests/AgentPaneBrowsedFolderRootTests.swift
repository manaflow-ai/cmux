import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

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
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
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

    /// Picking the home folder in the Open panel opens no more than before: the home folder stays
    /// the answer to the home question (`workspace.useFolder`), never a side effect of a pick.
    @Test func pickingTheHomeFolderGrantsNothing() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nkyvn-home-\(UUID().uuidString)").path
        let inside = home + "/src"
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.transport.homeFolder = home
        model.onBrowseProject = { home }
        _ = await model.respond(to: .browseProject)
        #expect(model.transport.addedRoots.isEmpty)
        model.onBrowseProject = { inside }
        _ = await model.respond(to: .browseProject)
        #expect(model.transport.addedRoots == [AcpmuxPathPolicy.canonical(inside)].compactMap { $0 })
    }
}
