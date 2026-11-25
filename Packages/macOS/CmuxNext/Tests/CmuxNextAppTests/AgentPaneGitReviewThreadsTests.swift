@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Review comments in the Changes view (cx-ncc.77.2, Codex desktop's inline PR comments):
/// `git.pullRequest {action: "threads"}` reads the branch's pull request review threads with the
/// cmux GitHub App through acpmux (or the person's gh there), each with its file, line, side and
/// comments. It only reads, so it needs no click, but only for a chat on this Mac. A closure stands
/// in for acpmux's GitHub op and records what it was asked; no `gh` is needed here.
@MainActor
struct AgentPaneGitReviewThreadsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    nonisolated private static let graphQL = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
         {"isResolved":false,"isOutdated":false,"path":"a.txt","line":2,"diffSide":"RIGHT","comments":{"nodes":[
          {"author":{"login":"reviewer"},"body":"Say three here?","url":"https://github.com/o/r/pull/7#discussion_r1"},
          {"author":null,"body":"Agreed.","url":"javascript:alert(1)"}]}},
         {"isResolved":true,"isOutdated":true,"path":"b.txt","line":null,"diffSide":"LEFT","comments":{"nodes":[
          {"author":{"login":"reviewer"},"body":"Old note","url":"https://github.com/o/r/pull/7#discussion_r2"}]}}]}}}}}
        """

    /// What the fake GitHub was asked, op and path or query.
    // Called from the @Sendable GitHub closure off the main actor; the lock guards `values`.
    nonisolated final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    /// A repository whose commit is the pull request's head and whose `origin` is github.com/o/r,
    /// and a fake acpmux GitHub op: `pulls?head=` answers the pull request in `state` (nil: none),
    /// and `graphql` answers `graphQL`.
    private static func rig(state: String? = "open") throws -> (folder: String, github: AgentPaneGitPullRequest.GitHubCall, asked: Asked) {
        let base = FileManager.default.temporaryDirectory.appending(path: "git-pr-threads-\(UUID().uuidString)").path
        let folder = base + "/repo"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "one\ntwo\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try "old\n".write(toFile: folder + "/b.txt", atomically: true, encoding: .utf8)
        try git(folder, "init", "-q", "-b", "feature")
        try git(folder, "remote", "add", "origin", "https://github.com/o/r.git")
        try git(folder, "add", ".")
        try git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "head")
        let head = try git(folder, "rev-parse", "HEAD")
        let asked = Asked()
        let pulls = state.map { #"[{"html_url":"https://github.com/o/r/pull/7","number":7,"state":"\#($0)","head":{"sha":"\#(head)"}}]"# } ?? "[]"
        let github: AgentPaneGitPullRequest.GitHubCall = { params in
            let op = params["op"] as? String ?? ""
            asked.append(op == "graphql" ? "graphql \(params["repo"] as? String ?? "") \(params["variables"].map { "\($0)" } ?? "")"
                                         : "\(op) \(params["repo"] as? String ?? "") \(params["path"] as? String ?? "")")
            switch op {
            case "get": return AgentPaneGitHubREST.Answer(ok: true, status: 200, body: Data(pulls.utf8), source: "app")
            case "graphql": return AgentPaneGitHubREST.Answer(ok: true, status: 200, body: Data(graphQL.utf8), source: "app")
            default: return AgentPaneGitHubREST.Answer(ok: false, status: 404, message: "Not Found")
            }
        }
        return (folder, github, asked)
    }

    @discardableResult
    private static func git(_ directory: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func model(_ folder: String, here: Bool = true) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [folder] }
        model.gitWritesHere = { here }
        return model
    }

    private static func threads(_ reply: [String: Any]) -> [[String: Any]] {
        ((reply["value"] as? [String: Any])?["threads"] as? [[String: Any]]) ?? []
    }

    /// Each thread with its file, line and side (a removed line's thread is on the deletions side,
    /// an outdated one has no line), whether it is resolved, and its comments with their authors.
    /// No click is needed, and nothing but the pull request lookup and the GraphQL read reaches GitHub.
    @Test func readsEachThreadWithoutAClick() async throws {
        let rig = try Self.rig()
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let reply = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: nil, github: rig.github)
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["number"] as? Int == 7)
        let threads = Self.threads(reply)
        try #require(threads.count == 2)
        #expect(threads[0]["path"] as? String == "a.txt")
        #expect(threads[0]["line"] as? Int == 2)
        #expect(threads[0]["side"] as? String == "additions")
        #expect(threads[0]["resolved"] as? Bool == false)
        let comments = try #require(threads[0]["comments"] as? [[String: Any]])
        #expect(comments.map { $0["author"] as? String } == ["reviewer", ""])
        #expect(comments.map { $0["body"] as? String } == ["Say three here?", "Agreed."])
        // Only https links reach the page.
        #expect(comments[0]["url"] as? String == "https://github.com/o/r/pull/7#discussion_r1")
        #expect(comments[1]["url"] is NSNull || comments[1]["url"] == nil)
        #expect(threads[1]["side"] as? String == "deletions")
        #expect(threads[1]["line"] == nil || threads[1]["line"] is NSNull)
        #expect(threads[1]["outdated"] as? Bool == true)
        // The working copy is the pull request's head, so each line is where GitHub put it.
        #expect(threads.map { $0["moved"] as? Bool } == [false, false])
        let calls = rig.asked.all
        #expect(calls.count == 2)
        #expect(calls.first == "get o/r pulls?head=o:feature&state=all&per_page=20")
        #expect(calls.last?.hasPrefix("graphql o/r ") == true, "\(calls)")
    }

    /// GitHub's line numbers are the pull request head's: a file edited here (by the agent, or a
    /// commit not pushed) marks its threads moved, so the page does not put them under whatever
    /// line now has that number. Without that head here to compare, every thread is moved.
    @Test func aFileChangedHereMovesItsThreads() async throws {
        let rig = try Self.rig()
        try "zero\none\ntwo\n".write(toFile: rig.folder + "/a.txt", atomically: true, encoding: .utf8)
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let edited = Self.threads(await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: nil, github: rig.github))
        #expect(edited.map { $0["path"] as? String } == ["a.txt", "b.txt"])
        #expect(edited.map { $0["moved"] as? Bool } == [true, false])
        try Self.git(rig.folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--amend", "-am", "rewritten")
        try Self.git(rig.folder, "reflog", "expire", "--expire=now", "--all")
        try Self.git(rig.folder, "gc", "-q", "--prune=now")
        let unknown = Self.threads(await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: nil, github: rig.github))
        #expect(unknown.map { $0["moved"] as? Bool } == [true, true])
    }

    /// The branch's merged or closed pull request is not this work: its threads are not shown.
    @Test func aMergedPullRequestsThreadsAreNotShown() async throws {
        let rig = try Self.rig(state: "closed")
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let reply = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: nil, github: rig.github)
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(Self.threads(reply).isEmpty)
        #expect(rig.asked.all == ["get o/r pulls?head=o:feature&state=all&per_page=20"])
    }

    /// A branch with no pull request has no threads (not an error); a chat on another machine is
    /// refused before GitHub is asked.
    @Test func noPullRequestHasNoThreadsAndRemoteChatsAreRefused() async throws {
        let rig = try Self.rig(state: nil)
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let none = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: nil, github: rig.github)
        #expect(none["ok"] as? Bool == true, "\(none)")
        #expect(Self.threads(none).isEmpty)
        #expect(rig.asked.all == ["get o/r pulls?head=o:feature&state=all&per_page=20"])
        let remote = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder, here: false), gh: nil, github: rig.github)
        #expect((remote["error"] as? [String: Any])?["code"] as? String == "git.remote", "\(remote)")
        #expect(rig.asked.all.count == 1)
    }
}
