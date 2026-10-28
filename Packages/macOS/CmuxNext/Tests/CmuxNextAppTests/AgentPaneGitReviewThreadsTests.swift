@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// Review comments in the Changes view (cx-ncc.77.2, Codex desktop's inline PR comments):
/// `git.pullRequest {action: "threads"}` reads the branch's pull request review threads with the
/// GitHub CLI, each with its file, line, side and comments. It only reads, so it needs no click,
/// but only for a chat on this Mac. A script stands in for `gh` and records what it was asked.
@MainActor
struct AgentPaneGitReviewThreadsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let graphQL = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
         {"isResolved":false,"isOutdated":false,"path":"a.txt","line":2,"diffSide":"RIGHT","comments":{"nodes":[
          {"author":{"login":"reviewer"},"body":"Say three here?","url":"https://github.com/o/r/pull/7#discussion_r1"},
          {"author":null,"body":"Agreed.","url":"javascript:alert(1)"}]}},
         {"isResolved":true,"isOutdated":true,"path":"b.txt","line":null,"diffSide":"LEFT","comments":{"nodes":[
          {"author":{"login":"reviewer"},"body":"Old note","url":"https://github.com/o/r/pull/7#discussion_r2"}]}}]}}}}}
        """

    /// A repository whose commit is the pull request's head, and a fake `gh`: `pr view` answers
    /// the pull request in `state` (nil: none), with a warning first as gh may print, and
    /// `api graphql` prints `graphQL`.
    private static func rig(state: String? = "OPEN") throws -> (folder: String, gh: String) {
        let base = FileManager.default.temporaryDirectory.appending(path: "git-pr-threads-\(UUID().uuidString)").path
        let folder = base + "/repo", gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "one\ntwo\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try "old\n".write(toFile: folder + "/b.txt", atomically: true, encoding: .utf8)
        try git(folder, "init", "-q")
        try git(folder, "add", ".")
        try git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "head")
        let head = try git(folder, "rev-parse", "HEAD")
        try graphQL.write(toFile: base + "/graphql.json", atomically: true, encoding: .utf8)
        if let state {
            try #"{"url":"https://github.com/o/r/pull/7","number":7,"state":"\#(state)","headRefOid":"\#(head)"}"#
                .write(toFile: base + "/view.json", atomically: true, encoding: .utf8)
        }
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" | head -c 160 | head -n 1 >> "$0.calls"
            [ "$(pwd -P)" = "$(cd '\(folder)' && pwd -P)" ] || exit 3
            case "$1 $2" in
            "pr view") [ -f "$(dirname "$0")/view.json" ] || { echo 'no pull requests found for branch "feature"' >&2; exit 1; }
                echo "A new release of gh is available" >&2; cat "$(dirname "$0")/view.json" ;;
            "api graphql") cat "$(dirname "$0")/graphql.json" ;;
            *) exit 2 ;;
            esac
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return (folder, gh)
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

    private static func calls(_ gh: String) -> [String] {
        ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private static func model(_ folder: String, here: Bool = true) -> AgentPaneModel {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.workspaceRoots = { [folder] }
        model.gitWritesHere = { here }
        return model
    }

    private static func threads(_ reply: [String: Any]) -> [[String: Any]] {
        ((reply["value"] as? [String: Any])?["threads"] as? [[String: Any]]) ?? []
    }

    /// Each thread with its file, line and side (a removed line's thread is on the deletions side,
    /// an outdated one has no line), whether it is resolved, and its comments with their authors.
    /// No click is needed, and nothing but `pr view` and the GraphQL read reaches gh.
    @Test func readsEachThreadWithoutAClick() async throws {
        let rig = try Self.rig()
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let reply = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: rig.gh)
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
        let calls = Self.calls(rig.gh)
        #expect(calls.count == 2)
        #expect(calls.first == "pr view --json url,number,state,headRefOid")
        #expect(calls.last?.hasPrefix("api graphql -f owner=o -f name=r -F number=7 ") == true, "\(calls)")
    }

    /// GitHub's line numbers are the pull request head's: a file edited here (by the agent, or a
    /// commit not pushed) marks its threads moved, so the page does not put them under whatever
    /// line now has that number. Without that head here to compare, every thread is moved.
    @Test func aFileChangedHereMovesItsThreads() async throws {
        let rig = try Self.rig()
        try "zero\none\ntwo\n".write(toFile: rig.folder + "/a.txt", atomically: true, encoding: .utf8)
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let edited = Self.threads(await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: rig.gh))
        #expect(edited.map { $0["path"] as? String } == ["a.txt", "b.txt"])
        #expect(edited.map { $0["moved"] as? Bool } == [true, false])
        try Self.git(rig.folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--amend", "-am", "rewritten")
        try Self.git(rig.folder, "reflog", "expire", "--expire=now", "--all")
        try Self.git(rig.folder, "gc", "-q", "--prune=now")
        let unknown = Self.threads(await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: rig.gh))
        #expect(unknown.map { $0["moved"] as? Bool } == [true, true])
    }

    /// The branch's merged or closed pull request is not this work: its threads are not shown.
    @Test func aMergedPullRequestsThreadsAreNotShown() async throws {
        let rig = try Self.rig(state: "MERGED")
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let reply = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: rig.gh)
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(Self.threads(reply).isEmpty)
        #expect(Self.calls(rig.gh) == ["pr view --json url,number,state,headRefOid"])
    }

    /// A branch with no pull request has no threads (not an error); a chat on another machine is
    /// refused before gh runs.
    @Test func noPullRequestHasNoThreadsAndRemoteChatsAreRefused() async throws {
        let rig = try Self.rig(state: nil)
        let request = try #require(AgentPaneGitPullRequest(params: ["cwd": rig.folder, "action": "threads"]))
        let none = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder), gh: rig.gh)
        #expect(none["ok"] as? Bool == true, "\(none)")
        #expect(Self.threads(none).isEmpty)
        #expect(Self.calls(rig.gh) == ["pr view --json url,number,state,headRefOid"])
        let remote = await AgentPaneGitPullRequest.reply(to: request, in: Self.model(rig.folder, here: false), gh: rig.gh)
        #expect((remote["error"] as? [String: Any])?["code"] as? String == "git.remote", "\(remote)")
        #expect(Self.calls(rig.gh).count == 1)
    }
}
