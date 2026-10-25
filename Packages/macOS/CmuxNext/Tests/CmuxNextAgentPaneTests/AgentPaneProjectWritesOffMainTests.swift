#if DEBUG
@testable import CmuxNextAgentPane
@testable import CmuxNextCompat
import Foundation
import Testing

/// Edit CLAUDE.md creates the missing file and, when the tab cannot open, takes the empty file
/// back. Both are file writes after a click; they run off the main thread, through the checked
/// seams, so a recording blocking table sees neither on main.
@MainActor @Suite struct AgentPaneProjectWritesOffMainTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func theCreateAndTheTakeBackRunOffTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "instructions-off-main-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [folder] }
        model.onOpenFile = { _, _ in false }  // the tab cannot open: the empty file is taken back
        model.transport.gestures.record()

        let table = BlockingViolationTable(mode: .record)
        let reply = await BlockingViolationTable.$scoped.withValue(table) {
            await model.respond(to: AgentPaneRequest(body: [
                "method": "project.instructions", "params": ["cwd": folder, "name": "CLAUDE.md"],
            ]))
        }
        await table.flush()

        #expect((reply["error"] as? [String: Any])?["code"] as? String == "open_failed", "\(reply)")
        #expect(!FileManager.default.fileExists(atPath: folder + "/CLAUDE.md"), "the empty file it made is taken back")
        let onMain = BlockingDetector(table: table).sites.map(\.location).filter { $0.contains("AgentPaneProjectInstructions.swift") }
        #expect(onMain.isEmpty, "file I/O on the main thread at \(onMain)")
    }
}
#endif
