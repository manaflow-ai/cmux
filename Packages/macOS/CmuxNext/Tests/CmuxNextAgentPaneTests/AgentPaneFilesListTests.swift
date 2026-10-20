import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `file.list` (Lucas 2026-10-19): the chat's Files view reads one folder's children
/// through the session host's `git.files.list`, only in the chat's folder or a folder inside it.
struct AgentPaneFilesListTests {
    private actor FolderHost: AgentPaneHostProviding {
        let cwd: String
        init(cwd: String) { self.cwd = cwd }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
            AgentPaneSessionFolder(cwd: cwd, isLocal: true)
        }
    }

    @Test @MainActor func bindsListingToTheHostFolderAndRefusesEscapingSymlinks() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("files-list-\(UUID().uuidString)")
        let chat = temporary.appendingPathComponent("chat")
        let outside = temporary.appendingPathComponent("outside")
        let subfolder = chat.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let link = chat.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let model = AgentPaneModel(host: FolderHost(cwd: chat.path), sessionId: "chat")
        var dispatched: [AgentPaneGitRequest] = []
        model.onGit = { request in
            dispatched.append(request)
            return Data("{\"entries\":[]}".utf8)
        }
        for (cwd, path) in [(outside.path, outside.path), (chat.path, link.path)] {
            let reply = await model.respond(to: AgentPaneRequest(body: ["method": "file.list", "params": ["cwd": cwd, "path": path]]))
            #expect(reply["ok"] as? Bool == false)
            #expect(dispatched.isEmpty)
        }
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "file.list", "params": ["cwd": chat.path, "path": subfolder.path]]))
        #expect(reply["ok"] as? Bool == true)
        let root = try #require(AcpmuxPathPolicy.canonical(chat.path))
        let folder = try #require(AcpmuxPathPolicy.canonical(subfolder.path))
        #expect(dispatched == [.filesList(cwd: root, folder: folder)])
    }

    @Test func listsTheChatsFolderOrOneInsideIt() {
        #expect(AgentPaneGitRequest(method: "file.list", params: ["cwd": "/Users/you/app"])
            == .filesList(cwd: "/Users/you/app", folder: "/Users/you/app"))
        #expect(AgentPaneGitRequest(method: "file.list", params: ["cwd": "/Users/you/app", "path": "/Users/you/app/src/lib"])
            == .filesList(cwd: "/Users/you/app", folder: "/Users/you/app/src/lib"))
        #expect(AgentPaneGitRequest.filesList(cwd: "/Users/you/app", folder: "/Users/you/app/src").operation == "git.files.list")
    }

    @Test func refusesAFolderOutsideTheChatsFolder() {
        for path in ["/Users/you", "/Users/you/application", "/Users/you/app/../other", "/Users/you/app/./src", "src", "/Users/you/app/\u{0}"] {
            #expect(AgentPaneGitRequest(method: "file.list", params: ["cwd": "/Users/you/app", "path": path]) == nil)
        }
        #expect(AgentPaneGitRequest(method: "file.list", params: ["path": "/Users/you/app"]) == nil)
    }
}
