@testable import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import Testing

/// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): `git.pullRequest {action: "merge",
/// number}` merges the branch's pull request with the GitHub CLI, only after a real click, only
/// the pull request the page showed, and only when GitHub says it is ready (clean merge state,
/// every check passed) and its head is what this Mac has. It merges that head exactly
/// (`--match-head-commit`) with the user's default method. A script stands in for `gh`.
@MainActor
struct AgentPaneGitMergeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private struct Rig {
        let folder: String, gh: String, head: String

        var calls: [String] {
            ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// gh's `pr view` answer, with `head` unless another is given.
        func view(state: String = "OPEN", draft: Bool = false, mergeState: String = "CLEAN", check: String = "SUCCESS",
                  head: String? = nil) throws {
            let json = """
                {"url":"https://github.com/o/r/pull/7","number":7,"state":"\(state)","isDraft":\(draft),
                 "mergeStateStatus":"\(mergeState)","headRefOid":"\(head ?? self.head)",
                 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"\(check)"}]}
                """
            try json.write(toFile: (gh as NSString).deletingLastPathComponent + "/view.json", atomically: true, encoding: .utf8)
        }
    }

    /// The repository every rig copies: one commit, made once per test process with real git. Each rig
    /// changes only files beside its own copy, and the merge reads its copy (`rev-parse HEAD`), so the
    /// copies share nothing. Removed when the test process exits.
    private static let template = Result { () throws -> (folder: String, head: String) in
        let folder = FileManager.default.temporaryDirectory.appending(path: "git-pr-merge-template-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "one\n".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        try AgentPaneGitMergeTests.git(folder, "init", "-q")
        try AgentPaneGitMergeTests.git(folder, "add", ".")
        try AgentPaneGitMergeTests.git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one")
        let head = try AgentPaneGitMergeTests.git(folder, "rev-parse", "HEAD")
        AgentPaneGitMergeTests.templatePath.withLock { $0 = folder }
        atexit { AgentPaneGitMergeTests.templatePath.withLock { path in if let path { try? FileManager.default.removeItem(atPath: path) } } }
        return (folder, head)
    }

    /// The template's folder, for the exit handler (a C function pointer captures nothing).
    private nonisolated static let templatePath = Mutex<String?>(nil)

    /// A copy of the one-commit repository (a file copy, no git process) and a fake `gh`: `pr view`
    /// prints view.json, `repo view` the user's default method, and `pr merge` succeeds.
    private static func rig() throws -> Rig {
        let template = try Self.template.get()
        let base = FileManager.default.temporaryDirectory.appending(path: "git-pr-merge-\(UUID().uuidString)").path
        let folder = base + "/repo", gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: template.folder, toPath: folder)
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            [ "$(pwd -P)" = "$(cd '\(folder)' && pwd -P)" ] || exit 3
            case "$1 $2" in
            "pr view") if [ "$3" = "--json" ]; then cat "$(dirname "$0")/view.json"
                else echo "{\\"state\\":\\"$(cat "$0.after" 2>/dev/null || echo MERGED)\\"}"; fi ;;
            "repo view") echo '{"viewerDefaultMergeMethod":"REBASE"}' ;;
            "pr merge") exit 0 ;;
            *) exit 2 ;;
            esac
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        let rig = Rig(folder: folder, gh: gh, head: template.head)
        try rig.view()
        return rig
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

    private static func model(_ folder: String) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.workspaceRoots = { [folder] }
        model.gitWritesHere = { true }
        return model
    }

    private static func merge(_ rig: Rig, number: Int = 7, url: String = "https://github.com/o/r/pull/7",
                              click: Bool = true) async throws -> [String: Any] {
        let model = Self.model(rig.folder)
        if click { model.transport.gestures.record() }
        let request = try #require(AgentPaneGitPullRequest(params: [
            "cwd": rig.folder, "action": "merge", "number": number, "url": url,
        ]))
        return await AgentPaneGitPullRequest.reply(to: request, in: model, gh: rig.gh)
    }

    /// A green pull request whose head this Mac has merges, at exactly that head, with the user's
    /// default method; the reply names it.
    @Test func mergesTheGreenPullRequestItShowed() async throws {
        let rig = try Self.rig()
        let reply = try await Self.merge(rig)
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["number"] as? Int == 7)
        #expect((reply["value"] as? [String: Any])?["merged"] as? Bool == true)
        let url = "https://github.com/o/r/pull/7"
        #expect(rig.calls.suffix(3) == [
            "repo view github.com/o/r --json viewerDefaultMergeMethod",
            "pr merge \(url) --rebase --match-head-commit \(rig.head)",
            "pr view \(url) --json state",
        ], "\(rig.calls)")
    }

    /// A base branch with a merge queue takes the pull request into the queue: the reply says it
    /// is queued, not merged.
    @Test func aMergeQueueSaysQueued() async throws {
        let rig = try Self.rig()
        try "OPEN".write(toFile: rig.gh + ".after", atomically: true, encoding: .utf8)
        let reply = try await Self.merge(rig)
        #expect((reply["value"] as? [String: Any])?["merged"] as? Bool == false, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["queued"] as? Bool == true)
    }

    /// No click, another pull request than the one shown, a draft, a closed one, a failing check,
    /// a merge state GitHub does not call clean (a required review, conflicts), or a head this Mac
    /// does not have: nothing is merged, and the reply says why.
    @Test func refusesUnlessReadyAndShown() async throws {
        let rig = try Self.rig()
        let unclicked = try await Self.merge(rig, click: false)
        #expect((unclicked["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        let other = try await Self.merge(rig, number: 8)
        #expect(other["ok"] as? Bool == false)
        // Another chat's pull request with the same number, in another repository.
        let elsewhere = try await Self.merge(rig, url: "https://github.com/o/other/pull/7")
        #expect((elsewhere["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneGitPullRequest.mergeChangedMessage)
        // Each alone: a draft, closed, a failing or running check, GitHub's merge state not clean,
        // behind its base, not worked out yet, or a head this Mac does not have.
        let cases: [(state: String, draft: Bool, mergeState: String, check: String, head: String?)] = [
            ("OPEN", true, "CLEAN", "SUCCESS", nil),
            ("CLOSED", false, "CLEAN", "SUCCESS", nil),
            ("OPEN", false, "CLEAN", "FAILURE", nil),
            ("OPEN", false, "CLEAN", "", nil),
            ("OPEN", false, "BLOCKED", "SUCCESS", nil),
            ("OPEN", false, "BEHIND", "SUCCESS", nil),
            ("OPEN", false, "UNKNOWN", "SUCCESS", nil),
            ("OPEN", false, "CLEAN", "SUCCESS", String(repeating: "a", count: 40)),
        ]
        for refused in cases {
            try rig.view(state: refused.state, draft: refused.draft, mergeState: refused.mergeState, check: refused.check,
                         head: refused.head)
            let reply = try await Self.merge(rig)
            #expect(reply["ok"] as? Bool == false, "\(refused) \(reply)")
            #expect(((reply["error"] as? [String: Any])?["userMessage"] as? String)?.isEmpty == false)
        }
        #expect(!rig.calls.contains { $0.hasPrefix("pr merge") }, "\(rig.calls)")
    }
}
