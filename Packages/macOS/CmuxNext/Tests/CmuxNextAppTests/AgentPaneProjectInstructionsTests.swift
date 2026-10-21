@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The chat menu's Edit CLAUDE.md (cx-ncc.65, Claude desktop's project instructions): after a real
/// click in the pane, the chat folder's instructions file opens in a file tab, created empty when
/// the folder has none and never overwritten. A chat on another machine, a folder outside the
/// pane's, a link out of it, no gesture and another file name are refused.
@MainActor
struct AgentPaneProjectInstructionsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane whose folder is a new temporary folder, with the opened files recorded.
    private final class Rig {
        let folder: String
        let model = AgentPaneModel(host: NoHost())
        var opened: [(String, AgentPaneFileTarget)] = []

        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "instructions-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let root = folder
            model.workspaceRoots = { [root] }
            model.onOpenFile = { [weak self] url, target, _ in
                self?.opened.append((url.path, target))
                return true
            }
        }

        func ask(cwd: String? = nil, name: String = "CLAUDE.md", gesture: Bool = true) async -> [String: Any] {
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: [
                "method": "project.instructions", "params": ["cwd": cwd ?? folder, "name": name],
            ]))
        }

        var openedPaths: [String] { opened.map { AcpmuxPathPolicy.canonical($0.0) ?? $0.0 } }
        func canonical(_ name: String) -> String { (AcpmuxPathPolicy.canonical(folder) ?? folder) + "/" + name }
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    /// A folder without the file gets an empty one, opened in a tab; asked again, the edited file
    /// opens as it is.
    @Test func createsTheMissingFileThenOpensItInATab() async throws {
        let rig = try Rig()
        let first = await rig.ask()
        #expect(Self.errorCode(first) == nil, "\(first)")
        #expect((first["value"] as? [String: Any])?["created"] as? Bool == true)
        #expect(FileManager.default.contents(atPath: rig.folder + "/CLAUDE.md") == Data())
        #expect(rig.openedPaths == [rig.canonical("CLAUDE.md")])
        #expect(rig.opened.map(\.1) == [.tab])

        try "Use tabs.\n".write(toFile: rig.folder + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let again = await rig.ask()
        #expect((again["value"] as? [String: Any])?["created"] as? Bool == false)
        #expect(try String(contentsOfFile: rig.folder + "/CLAUDE.md", encoding: .utf8) == "Use tabs.\n")
        #expect(rig.openedPaths.count == 2)
    }

    /// AGENTS.md for a Codex chat, the same way.
    @Test func opensAgentsMdToo() async throws {
        let rig = try Rig()
        let reply = await rig.ask(name: "AGENTS.md")
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(rig.openedPaths == [rig.canonical("AGENTS.md")])
    }

    /// A CLAUDE.md that links to the folder's AGENTS.md (one file for every harness) opens that
    /// file, the one both names read.
    @Test func opensAClaudeMdThatLinksToAgentsMd() async throws {
        let rig = try Rig()
        try "Use tabs.\n".write(toFile: rig.folder + "/AGENTS.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/CLAUDE.md", withDestinationPath: "AGENTS.md")
        let reply = await rig.ask()
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(rig.openedPaths == [rig.canonical("AGENTS.md")])
    }

    /// A tab that can't open leaves no empty file behind: the folder is as it was.
    @Test func aFailedOpenLeavesNoEmptyFile() async throws {
        let rig = try Rig()
        rig.model.onOpenFile = { _, _, _ in false }
        #expect(Self.errorCode(await rig.ask()) == "open_failed")
        #expect(!FileManager.default.fileExists(atPath: rig.folder + "/CLAUDE.md"))
    }

    /// Each refusal opens and writes nothing.
    @Test func refusesWithoutAGestureOutsideTheFoldersOnAnotherMachineOrAnotherName() async throws {
        let rig = try Rig()
        #expect(Self.errorCode(await rig.ask(gesture: false)) == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(Self.errorCode(await rig.ask(name: "notes.md")) == AgentPaneTransportError.pathInvalid.rawValue)
        #expect(Self.errorCode(await rig.ask(name: "../CLAUDE.md")) == AgentPaneTransportError.pathInvalid.rawValue)

        let outside = FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        #expect(Self.errorCode(await rig.ask(cwd: outside)) == AgentPaneTransportError.pathOutsideRoots.rawValue)
        #expect(!FileManager.default.fileExists(atPath: outside + "/CLAUDE.md"))

        // A CLAUDE.md that links out of the folder is never opened.
        try "secret".write(toFile: outside + "/target.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/AGENTS.md", withDestinationPath: outside + "/target.md")
        #expect(Self.errorCode(await rig.ask(name: "AGENTS.md")) == AgentPaneTransportError.pathOutsideRoots.rawValue)

        // Nor one that links to a page inside it: the tab would load it as a page.
        try "<script></script>".write(toFile: rig.folder + "/page.html", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/CLAUDE.md", withDestinationPath: rig.folder + "/page.html")
        #expect(Self.errorCode(await rig.ask()) == AgentPaneTransportError.pathInvalid.rawValue)
        try FileManager.default.removeItem(atPath: rig.folder + "/CLAUDE.md")

        rig.model.remoteChat = true
        #expect(Self.errorCode(await rig.ask()) == "unsupported")
        #expect(!FileManager.default.fileExists(atPath: rig.folder + "/CLAUDE.md"))
        #expect(rig.opened.isEmpty)
    }
}
