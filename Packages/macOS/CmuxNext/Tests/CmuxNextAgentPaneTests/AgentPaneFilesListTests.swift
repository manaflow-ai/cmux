import Testing
@testable import CmuxNextAgentPane

/// `file.list` (labs chatViewer, Lucas 2026-10-19): the chat's Files view reads one folder's children
/// through the session host's `git.files.list`, only in the chat's folder or a folder inside it.
struct AgentPaneFilesListTests {
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
