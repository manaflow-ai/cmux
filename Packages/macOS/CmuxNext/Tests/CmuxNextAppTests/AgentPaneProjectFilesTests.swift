@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The chat menu's Add Files to Project (cx-ncc.67, Claude desktop's project knowledge): after a real
/// click in the pane, the files the user picks are copied into the chat folder's `.cmux/context/`
/// and named in its CLAUDE.md (an `@` import) or AGENTS.md, which then opens in a tab, so every chat
/// in the folder reads them. A copy never overwrites; a cancelled pick changes nothing. A chat on
/// another machine, a folder outside the pane's, no gesture and a `.cmux` that links out are refused.
@MainActor
struct AgentPaneProjectFilesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane whose folder is a new temporary folder, picking `picks`, with the opened files recorded.
    private final class Rig {
        let folder: String
        let source: String
        let model = AgentPaneModel(host: NoHost())
        var picks: [URL] = []
        var opened: [String] = []

        init() throws {
            folder = Self.temporary("project")
            source = Self.temporary("downloads")
            let root = folder
            model.workspaceRoots = { [root] }
            model.onOpenFile = { [weak self] url, _ in
                self?.opened.append(url.lastPathComponent)
                return true
            }
            model.onChooseFiles = { [weak self] in self?.picks ?? [] }
        }

        static func temporary(_ name: String) -> String {
            let path = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)").path
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        /// A file in the downloads folder to pick.
        func file(_ name: String, _ text: String) throws -> URL {
            let url = URL(fileURLWithPath: source).appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func add(cwd: String? = nil, name: String = "CLAUDE.md", gesture: Bool = true) async -> [String: Any] {
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: [
                "method": "project.addFiles", "params": ["cwd": cwd ?? folder, "name": name],
            ]))
        }

        func read(_ name: String) -> String? { try? String(contentsOfFile: folder + "/" + name, encoding: .utf8) }
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func added(_ reply: [String: Any]) -> [String]? {
        (reply["value"] as? [String: Any])?["added"] as? [String]
    }

    /// Picked files are copied into `.cmux/context/` and imported from a new CLAUDE.md, which opens;
    /// a second pick appends to it, and a name already taken gets a number instead of overwriting.
    @Test func copiesPickedFilesAndImportsThemFromClaudeMd() async throws {
        let rig = try Rig()
        rig.picks = [try rig.file("spec.md", "# Spec"), try rig.file("style guide.txt", "Tabs.")]
        let first = await rig.add()
        #expect(Self.errorCode(first) == nil, "\(first)")
        #expect(Self.added(first) == [".cmux/context/spec.md", ".cmux/context/style-guide.txt"])
        #expect(rig.read(".cmux/context/spec.md") == "# Spec")
        #expect(rig.read(".cmux/context/style-guide.txt") == "Tabs.")
        #expect(rig.read("CLAUDE.md") == "@.cmux/context/spec.md\n@.cmux/context/style-guide.txt\n")
        #expect(rig.opened == ["CLAUDE.md"])

        try "Use tabs.\n\n@.cmux/context/spec.md\n@.cmux/context/style-guide.txt".write(
            toFile: rig.folder + "/CLAUDE.md", atomically: true, encoding: .utf8)
        rig.picks = [try rig.file("spec.md", "# Spec v2")]
        let second = await rig.add()
        #expect(Self.added(second) == [".cmux/context/spec-2.md"])
        #expect(rig.read(".cmux/context/spec.md") == "# Spec")
        #expect(rig.read(".cmux/context/spec-2.md") == "# Spec v2")
        #expect(rig.read("CLAUDE.md")
            == "Use tabs.\n\n@.cmux/context/spec.md\n@.cmux/context/style-guide.txt\n@.cmux/context/spec-2.md\n")
    }

    /// A Codex chat's AGENTS.md names the files to read (it has no imports).
    @Test func namesThemInAgentsMd() async throws {
        let rig = try Rig()
        rig.picks = [try rig.file("spec.md", "# Spec")]
        let reply = await rig.add(name: "AGENTS.md")
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(rig.read("AGENTS.md") == "Read `.cmux/context/spec.md` for project context.\n")
        #expect(rig.opened == ["AGENTS.md"])
    }

    /// A cancelled pick writes and opens nothing.
    @Test func cancelledPickChangesNothing() async throws {
        let rig = try Rig()
        let reply = await rig.add()
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect(Self.added(reply) == [])
        #expect(!FileManager.default.fileExists(atPath: rig.folder + "/.cmux"))
        #expect(!FileManager.default.fileExists(atPath: rig.folder + "/CLAUDE.md"))
        #expect(rig.opened.isEmpty)
    }

    /// Each refusal copies, writes and opens nothing.
    @Test func refusesWithoutAGestureOutsideTheFoldersOnAnotherMachineOrThroughALinkOut() async throws {
        let rig = try Rig()
        rig.picks = [try rig.file("spec.md", "# Spec")]
        #expect(Self.errorCode(await rig.add(gesture: false)) == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(Self.errorCode(await rig.add(name: "notes.md")) == AgentPaneTransportError.pathInvalid.rawValue)

        let outside = Rig.temporary("elsewhere")
        #expect(Self.errorCode(await rig.add(cwd: outside)) == AgentPaneTransportError.pathOutsideRoots.rawValue)
        #expect(!FileManager.default.fileExists(atPath: outside + "/.cmux"))

        // A `.cmux` that links out of the folder would put the copies there.
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/.cmux", withDestinationPath: outside)
        #expect(Self.errorCode(await rig.add()) == AgentPaneTransportError.pathOutsideRoots.rawValue)
        #expect(!FileManager.default.fileExists(atPath: outside + "/context"))
        try FileManager.default.removeItem(atPath: rig.folder + "/.cmux")

        // A CLAUDE.md that links out of the folder is never appended to.
        try "secret".write(toFile: outside + "/target.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: rig.folder + "/CLAUDE.md", withDestinationPath: outside + "/target.md")
        #expect(Self.errorCode(await rig.add()) == AgentPaneTransportError.pathOutsideRoots.rawValue)
        #expect(try String(contentsOfFile: outside + "/target.md", encoding: .utf8) == "secret")
        try FileManager.default.removeItem(atPath: rig.folder + "/CLAUDE.md")

        rig.model.remoteChat = true
        #expect(Self.errorCode(await rig.add()) == "unsupported")
        #expect(!FileManager.default.fileExists(atPath: rig.folder + "/CLAUDE.md"))
        #expect(rig.opened.isEmpty)
    }
}
