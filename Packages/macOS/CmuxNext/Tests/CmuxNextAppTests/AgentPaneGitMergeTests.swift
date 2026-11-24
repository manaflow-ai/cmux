@testable import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import Testing

/// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): `git.pullRequest {action: "merge",
/// number}` merges the branch's pull request through acpmux (the cmux GitHub App, or the person's
/// gh there), only after a real click, only the pull request the page showed, and only when GitHub
/// says it is ready (clean merge state, every check passed) and its head is what this Mac has. It
/// merges that head exactly (the REST merge's `sha`) with the user's default method. A closure
/// stands in for acpmux's GitHub op; no `gh` is needed here.
@MainActor
struct AgentPaneGitMergeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The fake GitHub: the pull request it answers, and what it was asked.
    // Called from the @Sendable GitHub closure off the main actor; the lock guards every field.
    nonisolated final class GitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var shown = ""
        private var asked: [String] = []
        /// The state a read after the merge answers (a merge queue keeps it OPEN).
        var after: String {
            get { lock.withLock { afterState } }
            set { lock.withLock { afterState = newValue } }
        }
        private var afterState = "MERGED"
        private var merged = false

        var calls: [String] { lock.withLock { asked } }

        func show(_ json: String) { lock.withLock { shown = json } }

        func call(_ params: [String: any Sendable]) -> AgentPaneGitHubREST.Answer {
            let op = params["op"] as? String ?? ""
            return lock.withLock {
                switch op {
                case "graphql":
                    let variables = params["variables"] as? [String: any Sendable] ?? [:]
                    asked.append("graphql \(params["repo"] as? String ?? "") \(variables["number"] as? Int ?? 0)")
                    let pull = merged ? #"{"url":"https://github.com/o/r/pull/7","number":7,"state":"\#(afterState)"}"# : shown
                    let body = #"{"data":{"repository":{"viewerDefaultMergeMethod":"REBASE","pullRequest":\#(pull)}}}"#
                    return AgentPaneGitHubREST.Answer(ok: true, status: 200, body: Data(body.utf8), source: "app")
                case "pr.merge":
                    asked.append("pr.merge \(params["repo"] as? String ?? "") \(params["number"] as? Int ?? 0) \(params["method"] as? String ?? "") \(params["head"] as? String ?? "")")
                    merged = true
                    return AgentPaneGitHubREST.Answer(ok: true, status: 200, body: Data(#"{"merged":true}"#.utf8), source: "app")
                default:
                    asked.append(op)
                    return AgentPaneGitHubREST.Answer(ok: false, status: 404, message: "Not Found")
                }
            }
        }
    }

    private struct Rig {
        let folder: String, github: GitHub, head: String

        var calls: [String] { github.calls }

        /// GitHub's pull request, with `head` unless another is given.
        func view(state: String = "OPEN", draft: Bool = false, mergeState: String = "CLEAN", check: String = "SUCCESS",
                  head: String? = nil) {
            github.show("""
                {"url":"https://github.com/o/r/pull/7","number":7,"state":"\(state)","isDraft":\(draft),
                 "mergeStateStatus":"\(mergeState)","headRefOid":"\(head ?? self.head)",
                 "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
                  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"\(check)"}]}}}}]}}
                """)
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

    /// A copy of the one-commit repository (a file copy, no git process) and a fake GitHub that
    /// answers a clean, green pull request at its head.
    private static func rig() throws -> Rig {
        let template = try Self.template.get()
        let base = FileManager.default.temporaryDirectory.appending(path: "git-pr-merge-\(UUID().uuidString)").path
        let folder = base + "/repo"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: template.folder, toPath: folder)
        let rig = Rig(folder: folder, github: GitHub(), head: template.head)
        rig.view()
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
        let github = rig.github
        return await AgentPaneGitPullRequest.reply(to: request, in: model, gh: nil, github: { github.call($0) })
    }

    /// A green pull request whose head this Mac has merges, at exactly that head, with the user's
    /// default method; the reply names it.
    @Test func mergesTheGreenPullRequestItShowed() async throws {
        let rig = try Self.rig()
        let reply = try await Self.merge(rig)
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["number"] as? Int == 7)
        #expect((reply["value"] as? [String: Any])?["merged"] as? Bool == true)
        #expect(rig.calls == [
            "graphql o/r 7",
            "pr.merge o/r 7 rebase \(rig.head)",
            "graphql o/r 7",
        ], "\(rig.calls)")
    }

    /// A base branch with a merge queue takes the pull request into the queue: the reply says it
    /// is queued, not merged.
    @Test func aMergeQueueSaysQueued() async throws {
        let rig = try Self.rig()
        rig.github.after = "OPEN"
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
            rig.view(state: refused.state, draft: refused.draft, mergeState: refused.mergeState, check: refused.check,
                         head: refused.head)
            let reply = try await Self.merge(rig)
            #expect(reply["ok"] as? Bool == false, "\(refused) \(reply)")
            #expect(((reply["error"] as? [String: Any])?["userMessage"] as? String)?.isEmpty == false)
        }
        #expect(!rig.calls.contains { $0.hasPrefix("pr.merge") }, "\(rig.calls)")
    }
}
