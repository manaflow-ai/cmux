@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The Changes view's Stage hunk and Unstage hunk (cx-ncc.74, Codex desktop's): the page names one
/// hunk of a file by its lines as `git.diff` showed them; the App finds that hunk in its own read
/// of the file's diff and applies only it to the index. A hunk the App cannot find (the file
/// changed since, or the page edited the lines) stages nothing.
@MainActor
struct AgentPaneGitStageHunkTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Twenty lines committed; line 2 and line 19 changed, far enough apart for two hunks.
    private static func rig() throws -> (AgentPaneModel, String) {
        let repo = FileManager.default.temporaryDirectory.appending(path: "git-hunk-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q")
        let lines = (1...20).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
        var changed = lines
        changed[1] = "line two"
        changed[18] = "line nineteen"
        try (changed.joined(separator: "\n") + "\n").write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
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

    /// The second hunk's lines as the page shows them (three lines of context each side).
    private static let second = [" line 16", " line 17", " line 18", "-line 19", "+line nineteen", " line 20"]

    private static func request(_ method: String, _ repo: String, _ hunk: [String]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": ["cwd": repo, "paths": ["a.txt"], "hunk": hunk]])
    }

    /// Stage hunk stages that change alone; Unstage hunk takes it back out of the index.
    @Test func stagesAndUnstagesOneHunk() async throws {
        let (model, repo) = try Self.rig()
        model.transport.gestures.record()
        let staged = await model.respond(to: Self.request("git.stageHunk", repo, Self.second))
        #expect(staged["ok"] as? Bool == true, "\(staged)")
        let index = try Self.git(repo, "diff", "--cached")
        #expect(index.contains("+line nineteen"))
        #expect(!index.contains("+line two"))
        #expect(try Self.git(repo, "diff").contains("+line two"))

        model.transport.gestures.record()
        let unstaged = await model.respond(to: Self.request("git.unstageHunk", repo, Self.second))
        #expect(unstaged["ok"] as? Bool == true, "\(unstaged)")
        #expect(try Self.git(repo, "diff", "--cached").isEmpty)
    }

    /// Lines that are not a hunk of the file's diff (edited by the page, or stale) stage nothing,
    /// and a hunk request needs one path and changed lines.
    @Test func aHunkTheAppCannotFindStagesNothing() async throws {
        let (model, repo) = try Self.rig()
        model.transport.gestures.record()
        let edited = Self.second.map { $0 == "+line nineteen" ? "+rm -rf ~" : $0 }
        let reply = await model.respond(to: Self.request("git.stageHunk", repo, edited))
        #expect(reply["ok"] as? Bool == false)
        #expect(try Self.git(repo, "diff", "--cached").isEmpty)
        #expect(AgentPaneGitStage(method: "git.stageHunk", params: ["cwd": repo, "paths": ["a.txt", "b.txt"], "hunk": Self.second]) == nil)
        #expect(AgentPaneGitStage(method: "git.stageHunk", params: ["cwd": repo, "paths": ["a.txt"], "hunk": [" line 16"]]) == nil)
        #expect(AgentPaneGitStage(method: "git.stageHunk", params: ["cwd": repo, "paths": ["a.txt"], "hunk": ["x"]]) == nil)
    }
}
