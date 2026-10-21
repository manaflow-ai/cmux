import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Any file attaches in a chat on this Mac (Lawrence 2026-10-20): what the composer can't put in
/// the prompt (a binary, a large text file) is saved owner-only and named by its path.
@Suite struct AgentChatUploadsTests {
    @Test func savesEachFileOwnerOnlyUnderItsOwnName() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "agent-chat-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "upload", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let binary = Data([0, 1, 2, 0xff])
        let files = [AgentPaneUpload(name: "state.sqlite", data: binary), AgentPaneUpload(name: "state.sqlite", data: Data("b".utf8)),
                     AgentPaneUpload(name: "index.html", data: Data("<p>x</p>".utf8))]
        let paths = try AgentChatUploads.write(files, in: folder)
        #expect(paths.count == 3)
        #expect(Set(paths).count == 3, "two files with one name keep both")
        #expect(paths.map { ($0 as NSString).lastPathComponent } == ["state.sqlite", "state.sqlite", "index.html"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == binary)
        let mode = try FileManager.default.attributesOfItem(atPath: paths[2])[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }
}
