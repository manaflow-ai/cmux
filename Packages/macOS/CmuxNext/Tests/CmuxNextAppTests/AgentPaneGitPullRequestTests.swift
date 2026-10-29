@testable import CmuxNextAgentPane
import Foundation
import Testing
import CmuxNextWakeups

/// The Changes view's Create PR (cx-tcwj): the App opens the pushed branch's pull request with the
/// GitHub CLI, the open one when there is one. It never pushes (the session host's Push does,
/// cx-ncc.1): a branch with no upstream, or commits the upstream lacks, is refused. A local bare
/// repository stands in for the remote and a script for `gh`, which records what it was asked.
@MainActor
struct AgentPaneGitPullRequestTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A repository on branch `feature`, one commit ahead of `main` and not pushed, whose `origin`
    /// is a bare repository; a fake `gh` beside them.
    private struct Rig {
        let repo: String, remote: String, gh: String

        var calls: [String] {
            ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private static func rig() throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appending(path: "git-pr-\(UUID().uuidString)").path
        let repo = base + "/repo", remote = base + "/remote.git", gh = base + "/bin/gh"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/bin", withIntermediateDirectories: true)
        try git(base, "init", "-q", "--bare", remote)
        try git(repo, "init", "-q", "-b", "main")
        try git(repo, "config", "user.name", "t")
        try git(repo, "config", "user.email", "t@t")
        try git(repo, "remote", "add", "origin", remote)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt")
        try git(repo, "commit", "-q", "-m", "one")
        try git(repo, "push", "-q", "origin", "main")
        try git(repo, "checkout", "-q", "-b", "feature")
        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try git(repo, "commit", "-q", "-am", "Say two")
        // `gh pr view` answers once `gh pr create` made the pull request. `<gh>.viewerr` and
        // `<gh>.createerr` make that step fail with their text, as gh does on stderr (create also
        // warns about uncommitted changes first).
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            case "$1 $2" in
            "pr view") [ -f "$0.viewerr" ] && { cat "$0.viewerr" >&2; exit 1; }
                [ -f "$0.pr" ] && cat "$0.pr" && exit 0; echo 'no pull requests found for branch "feature"' >&2; exit 1 ;;
            "pr create") [ -f "$0.createerr" ] && { echo "Warning: 3 uncommitted changes" >&2; cat "$0.createerr" >&2; exit 1; }
                echo "https://github.com/o/r/pull/7"; echo '{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN"}' > "$0.pr" ;;
            *) exit 2 ;;
            esac
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return Rig(repo: repo, remote: remote, gh: gh)
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

    private static func request(_ repo: String) throws -> AgentPaneGitPullRequest {
        try #require(AgentPaneGitPullRequest(params: ["cwd": repo]))
    }

    /// A pushed branch gets a pull request from its commits; asked again, the open one comes back
    /// without a second.
    @Test func opensThePushedBranchsPullRequestOnce() async throws {
        let rig = try Self.rig()
        try Self.git(rig.repo, "push", "-q", "--set-upstream", "origin", "feature")
        let first = await AgentPaneGitPullRequest.run(try Self.request(rig.repo), roots: [rig.repo], gh: rig.gh)
        #expect(first == .opened(url: "https://github.com/o/r/pull/7", number: 7))
        let again = await AgentPaneGitPullRequest.run(try Self.request(rig.repo), roots: [rig.repo], gh: rig.gh)
        #expect(again == .opened(url: "https://github.com/o/r/pull/7", number: 7))
        #expect(rig.calls == ["pr view --json url,number,state", "pr create --fill", "pr view --json url,number,state"])
    }

    /// The branch's merged or closed pull request is not its open one: a new one is created. A
    /// view that fails for another reason (auth, network) creates nothing and says gh's reason; a
    /// create that fails says why, not gh's warning before it.
    @Test func onlyAnOpenPullRequestIsReusedAndGitHubsReasonShows() async throws {
        let rig = try Self.rig()
        try Self.git(rig.repo, "push", "-q", "--set-upstream", "origin", "feature")
        let request = try Self.request(rig.repo)
        try #"{"number":3,"url":"https://github.com/o/r/pull/3","state":"MERGED"}"#.write(toFile: rig.gh + ".pr", atomically: true, encoding: .utf8)
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .opened(url: "https://github.com/o/r/pull/7", number: 7))
        try FileManager.default.removeItem(atPath: rig.gh + ".pr")
        try "HTTP 401: Bad credentials (https://api.github.com/graphql)\n".write(toFile: rig.gh + ".viewerr", atomically: true, encoding: .utf8)
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh)
            == .refused("HTTP 401: Bad credentials (https://api.github.com/graphql)"))
        try FileManager.default.removeItem(atPath: rig.gh + ".viewerr")
        try "pull request create failed: GraphQL: No commits between main and feature\n"
            .write(toFile: rig.gh + ".createerr", atomically: true, encoding: .utf8)
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh)
            == .refused("pull request create failed: GraphQL: No commits between main and feature"))
        #expect(rig.calls.filter { $0.hasPrefix("pr create") }.count == 2)
    }

    /// No GitHub CLI, no branch checked out, a branch never pushed, commits not pushed yet, or a
    /// branch behind its upstream:
    /// nothing reaches `gh` or the remote, and the reply says why.
    @Test func refusalsNeverPushOrAskGitHub() async throws {
        let rig = try Self.rig()
        let request = try Self.request(rig.repo)
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: nil) == .refused(AgentPaneGitPullRequest.noGitHubCLIMessage))
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .refused(AgentPaneGitPullRequest.pushFirstMessage))
        #expect(try Self.git(rig.remote, "branch", "--list", "feature").isEmpty)
        try Self.git(rig.repo, "push", "-q", "--set-upstream", "origin", "feature")
        try "three\n".write(toFile: rig.repo + "/a.txt", atomically: true, encoding: .utf8)
        try Self.git(rig.repo, "commit", "-q", "-am", "Say three")
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .refused(AgentPaneGitPullRequest.pushFirstMessage))
        // Behind its upstream (pushed from elsewhere): gh would want to push, so it is refused too.
        try Self.git(rig.repo, "push", "-q", "origin", "feature")
        try Self.git(rig.repo, "reset", "-q", "--hard", "HEAD~1")
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .refused(AgentPaneGitPullRequest.pullFirstMessage))
        try Self.git(rig.repo, "checkout", "-q", "--detach")
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .refused(AgentPaneGitPullRequest.detachedMessage))
        #expect(rig.calls.isEmpty)
    }

    /// Through the pane: a request needs a real click or key and a chat on this Mac.
    @Test func thePaneNeedsAGestureAndAChatOnThisMac() async throws {
        let rig = try Self.rig()
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        model.workspaceRoots = { [rig.repo] }
        model.gitWritesHere = { true }
        let body: [String: Any] = ["method": "git.pullRequest", "params": ["cwd": rig.repo]]
        let unasked = await model.respond(to: AgentPaneRequest(body: body))
        #expect(unasked["ok"] as? Bool == false)
        model.gitWritesHere = { false }
        model.transport.gestures.record()
        let remote = await model.respond(to: AgentPaneRequest(body: body))
        #expect((remote["error"] as? [String: Any])?["code"] as? String == "git.remote", "\(remote)")
        #expect(try Self.git(rig.remote, "branch", "--list", "feature").isEmpty)
    }

    /// A worktree chat's branch (cx-lyqio.6) opens its pull request against the branch it was made
    /// from (`branch.<b>.cmuxBase`, New Worktree), not the repository's default: by the name that
    /// branch has on the remote. A base with no branch on the remote (a commit, a local branch never
    /// pushed, the remote's HEAD) leaves gh's default, as before.
    @Test func aWorktreeChatsPullRequestTargetsItsRecordedBase() async throws {
        let rig = try Self.rig()
        // `release` is on the remote as `rel`; the chat's branch was made from it.
        try Self.git(rig.repo, "checkout", "-q", "-b", "release", "main")
        try Self.git(rig.repo, "push", "-q", "--set-upstream", "origin", "release:rel")
        try Self.git(rig.repo, "checkout", "-q", "-b", "cmux/fix-login", "release")
        try "three\n".write(toFile: rig.repo + "/b.txt", atomically: true, encoding: .utf8)
        try Self.git(rig.repo, "add", "b.txt")
        try Self.git(rig.repo, "commit", "-q", "-m", "Say three")
        try Self.git(rig.repo, "push", "-q", "--set-upstream", "origin", "cmux/fix-login")
        let request = try Self.request(rig.repo)
        let creates = { rig.calls.filter { $0.hasPrefix("pr create") } }

        try Self.git(rig.repo, "config", "branch.cmux/fix-login.cmuxBase", "release")
        #expect(await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh) == .opened(url: "https://github.com/o/r/pull/7", number: 7))
        #expect(creates().last == "pr create --fill --base rel")

        // A remote branch as the base: its name on that remote.
        try FileManager.default.removeItem(atPath: rig.gh + ".pr")
        try Self.git(rig.repo, "config", "branch.cmux/fix-login.cmuxBase", "origin/rel")
        _ = await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh)
        #expect(creates().last == "pr create --fill --base rel")

        // No branch on the remote to target: a commit, a local branch never pushed, the remote's HEAD.
        try Self.git(rig.repo, "branch", "local-only", "release")
        try Self.git(rig.repo, "remote", "set-head", "origin", "main")
        for base in [try Self.git(rig.repo, "rev-parse", "release"), "local-only", "origin/HEAD"] {
            try FileManager.default.removeItem(atPath: rig.gh + ".pr")
            try Self.git(rig.repo, "config", "branch.cmux/fix-login.cmuxBase", base)
            _ = await AgentPaneGitPullRequest.run(request, roots: [rig.repo], gh: rig.gh)
            #expect(creates().last == "pr create --fill", "\(base)")
        }
        #expect(creates().count == 5)
    }
}
