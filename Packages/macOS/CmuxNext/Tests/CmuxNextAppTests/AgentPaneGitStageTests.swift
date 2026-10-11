import CmuxNextAgentPane
import Foundation
import Testing

/// The Changes view's Stage and Unstage (cx-tcwj): the page asks the App to run `git add` or
/// `git restore --staged` on files of the chat's repository. Each needs a real click or key in the
/// pane, a repository inside the pane's folders, and paths inside that repository.
@MainActor
struct AgentPaneGitStageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A repository with one commit and a changed and a new file, and a pane whose folder it is.
    private static func rig() throws -> (AgentPaneModel, String) {
        let repo = FileManager.default.temporaryDirectory.appending(path: "git-stage-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [repo] }
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

    private static func staged(_ repo: String) throws -> [String] {
        try git(repo, "diff", "--cached", "--name-only").split(separator: "\n").map(String.init)
    }

    private static func request(_ method: String, _ repo: String, _ paths: [String]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": ["cwd": repo, "paths": paths]])
    }

    @Test func stageThenUnstageAfterAClick() async throws {
        let (model, repo) = try Self.rig()
        model.transport.gestures.record()
        let staged = await model.respond(to: Self.request("git.stage", repo, ["a.txt", "b.txt"]))
        #expect(staged["ok"] as? Bool == true, "\(staged)")
        #expect(try Self.staged(repo) == ["a.txt", "b.txt"])

        model.transport.gestures.record()
        let unstaged = await model.respond(to: Self.request("git.unstage", repo, ["a.txt"]))
        #expect(unstaged["ok"] as? Bool == true, "\(unstaged)")
        #expect(try Self.staged(repo) == ["b.txt"])
    }

    /// No click or key in the pane: page script alone stages nothing.
    @Test func aStageWithoutAGestureIsRefused() async throws {
        let (model, repo) = try Self.rig()
        let reply = await model.respond(to: Self.request("git.stage", repo, ["a.txt"]))
        #expect(reply["ok"] as? Bool == false)
        #expect(try Self.staged(repo).isEmpty)
    }

    /// A repository outside the pane's folders, or a path that leaves the repository, is refused.
    @Test func foldersAndPathsOutsideThePaneAreRefused() async throws {
        let (model, repo) = try Self.rig()
        let (other, _) = try Self.rig()
        other.transport.gestures.record()
        let elsewhere = await other.respond(to: Self.request("git.stage", repo, ["a.txt"]))
        #expect(elsewhere["ok"] as? Bool == false)
        for path in ["../a.txt", "/etc/hosts", "", "x\u{0}y", "-n"] {
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.request("git.stage", repo, [path]))
            #expect(reply["ok"] as? Bool == false, "\(path)")
        }
        #expect(try Self.staged(repo).isEmpty)
    }
}
