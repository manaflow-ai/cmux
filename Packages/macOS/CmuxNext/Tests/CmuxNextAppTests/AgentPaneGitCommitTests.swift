import CmuxNextAgentPane
import Foundation
import Testing

/// The Changes view's Commit (cx-tcwj): the page asks the App to commit what is staged in the
/// chat's repository with the message the user edited. It needs a real click or key in the pane
/// and a repository inside the pane's folders; git's own refusal comes back as the reply's message.
@MainActor
struct AgentPaneGitCommitTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A repository with one commit and a staged change, and a pane whose folder it is.
    private static func rig() throws -> (AgentPaneModel, String) {
        let repo = FileManager.default.temporaryDirectory.appending(path: "git-commit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q")
        try git(repo, "config", "user.name", "t")
        try git(repo, "config", "user.email", "t@t")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt")
        try git(repo, "commit", "-q", "-m", "one")
        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt")
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [repo] }
        model.gitWritesHere = { true }
        return (model, repo)
    }

    @discardableResult
    private static func git(_ repo: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func lastMessage(_ repo: String) throws -> String {
        try git(repo, "log", "-1", "--format=%B").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func request(_ repo: String, _ message: Any) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "git.commit", "params": ["cwd": repo, "message": message]])
    }

    /// The message is the commit's, byte for byte, even one that looks like an option.
    @Test func aClickCommitsTheStagedChangeWithTheMessage() async throws {
        let (model, repo) = try Self.rig()
        model.transport.gestures.record()
        let message = "--amend: Say two\n\nThe file said one."
        let reply = await model.respond(to: Self.request(repo, message))
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(try Self.lastMessage(repo) == message)
        #expect(try Self.git(repo, "diff", "--cached", "--name-only").isEmpty)
    }

    /// No click or key in the pane: page script alone commits nothing.
    @Test func aCommitWithoutAGestureIsRefused() async throws {
        let (model, repo) = try Self.rig()
        let reply = await model.respond(to: Self.request(repo, "Say two"))
        #expect(reply["ok"] as? Bool == false)
        #expect(try Self.lastMessage(repo) == "one")
    }

    /// A blank message, a repository outside the pane, and nothing staged are each refused
    /// with a message the view can show.
    @Test func refusalsSayWhy() async throws {
        let (model, repo) = try Self.rig()
        for message: Any in [" \n", 7] {
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.request(repo, message))
            #expect(reply["ok"] as? Bool == false, "\(message)")
        }
        let (other, _) = try Self.rig()
        other.transport.gestures.record()
        let elsewhere = await other.respond(to: Self.request(repo, "Say two"))
        #expect(elsewhere["ok"] as? Bool == false)
        #expect(try Self.lastMessage(repo) == "one")

        try Self.git(repo, "restore", "--staged", "a.txt")
        model.transport.gestures.record()
        let empty = await model.respond(to: Self.request(repo, "Say two"))
        #expect(empty["ok"] as? Bool == false)
        let error = empty["error"] as? [String: Any]
        #expect(error?["code"] as? String == "git.failed", "\(empty)")
        #expect(error?["userMessage"] as? String == "Nothing is staged to commit.", "\(empty)")
        #expect(try Self.lastMessage(repo) == "one")
    }
}
