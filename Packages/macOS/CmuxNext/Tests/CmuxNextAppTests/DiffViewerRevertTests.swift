import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff tab's Revert (D3): `cmux.diff.git.discard` reverts files only after the native sheet,
/// `cmux.diff.git.discardHunk` reverts one hunk at once and hands the page an Undo token, and
/// `cmux.diff.git.undoDiscard` puts that hunk back. Each runs in the tab's own repository whatever
/// folder the page names, and each needs its own key or mouse event in the page: one event, one
/// revert.
@MainActor
@Suite(.serialized)
struct DiffViewerRevertTests {
    final class RecordingGit: DiffGitRunning, DiffGitReverting {
        var discards: [(AgentPaneGitDiscard, String)] = []
        var reapplied: [(AgentPaneGitDiscard.Undo, String)] = []
        var outcome = AgentPaneGitDiscard.Outcome.reverted(undo: nil)

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
            ["files": []]
        }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { nil }

        func discard(_ request: AgentPaneGitDiscard, in repository: String) async -> AgentPaneGitDiscard.Outcome {
            discards.append((request, repository))
            return outcome
        }

        func reapply(_ undo: AgentPaneGitDiscard.Undo, in repository: String) async -> String? {
            reapplied.append((undo, repository))
            return nil
        }
    }

    /// The sheets the provider asked for.
    final class PromptLog {
        var prompts: [DiffRevertPrompt] = []
    }

    static let repository = "/Users/dev/uploader"
    static let hunk = ["-// retry 3 times", "+// retry 9 times"]
    static let undo = AgentPaneGitDiscard.Undo(patch: "the hunk's patch", path: "install.sh", hash: "abc")

    /// A call backed by its own key or mouse event (`event`, the event's uptime).
    static func clicked(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.diff", userGesture: true, gestureEvent: event)
    }

    private static func provider(_ git: RecordingGit, answer: Bool, log: PromptLog) throws -> (DiffPageProvider, DiffSessionGrant, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-revert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let grant = try DiffSessionGrant.create(root: root, repository: repository)
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: git)
        provider.confirmRevert = { prompt in
            log.prompts.append(prompt)
            return answer
        }
        return (provider, grant, root)
    }

    @Test func aFileRevertsOnlyAfterTheSheetAndInTheTabsRepository() async throws {
        let git = RecordingGit()
        let log = PromptLog()
        let (provider, grant, root) = try Self.provider(git, answer: true, log: log)
        defer {
            grant.remove()
            try? FileManager.default.removeItem(at: root)
        }

        let config = try await provider.call("cmux.diff.config", params: [:], context: PageCallContext(page: "cmux.diff"))
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.git.discard") == true)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.git.undoDiscard") == true)

        // One renamed file and one other: two files, every path listed.
        _ = try await provider.call("cmux.diff.git.discard", params: [
            "paths": ["src/upload.ts", "src/old.ts", "README.md"], "sources": ["src/old.ts"], "scope": "uncommitted", "cwd": "/etc",
        ], context: Self.clicked(1))
        #expect(git.discards.map(\.1) == [Self.repository])
        #expect(git.discards.first?.0.cwd == Self.repository)
        #expect(git.discards.first?.0.paths == ["src/upload.ts", "src/old.ts", "README.md"])
        #expect(git.discards.first?.0.scope == .uncommitted)
        #expect(log.prompts.map(\.title) == [String(format: DiffPageStrings.revertManyTitle, 2)])
        #expect(log.prompts.first?.lines == [DiffPageStrings.revertUncommittedLine, DiffPageStrings.revertTrashLine,
                                             "src/upload.ts", "src/old.ts", "README.md"])

        // Without a click or key in the page nothing runs and no sheet shows.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.discard", params: ["paths": ["src/upload.ts"], "scope": "unstaged"],
                                        context: PageCallContext(page: "cmux.diff"))
        }
        // The event that ran one revert runs no second one.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.discard", params: ["paths": ["src/upload.ts"], "scope": "unstaged"],
                                        context: Self.clicked(1))
        }
        #expect(git.discards.count == 1)
        #expect(log.prompts.count == 1)

        // Staged and Branch are not revert scopes; a rename source must be one of the paths.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.discard", params: ["paths": ["src/upload.ts"], "scope": "staged"],
                                        context: Self.clicked(2))
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.discard", params: ["paths": ["a.ts"], "sources": ["b.ts"], "scope": "unstaged"],
                                        context: Self.clicked(3))
        }
        #expect(git.discards.count == 1)
        await provider.close()
    }

    /// Past six files the sheet lists six and says how many more.
    @Test func aLongRevertListsSixNamesAndCountsTheRest() throws {
        let paths = (1...9).map { "f\($0).txt" }
        let request = try #require(AgentPaneGitDiscard(method: "git.discard", params: ["cwd": "/r", "paths": paths, "scope": "unstaged"]))
        let prompt = DiffRevertPrompt(request)
        #expect(prompt.title == String(format: DiffPageStrings.revertManyTitle, 9))
        #expect(prompt.lines.dropFirst(2) == ArraySlice(Array(paths.prefix(6)) + [String(format: DiffPageStrings.revertAndMore, 3)]))
        let renamed = try #require(AgentPaneGitDiscard(method: "git.discard", params: ["cwd": "/r", "paths": ["new.ts", "old.ts"], "scope": "unstaged"]))
        #expect(DiffRevertPrompt(renamed, sources: ["old.ts"]).title == String(format: DiffPageStrings.revertOneTitle, "new.ts"))
    }

    @Test func aDeclinedSheetRevertsNothing() async throws {
        let git = RecordingGit()
        let log = PromptLog()
        let (provider, grant, root) = try Self.provider(git, answer: false, log: log)
        defer {
            grant.remove()
            try? FileManager.default.removeItem(at: root)
        }
        await #expect(throws: PageError.cancelled) {
            _ = try await provider.call("cmux.diff.git.discard", params: ["paths": ["src/upload.ts"], "scope": "unstaged"],
                                        context: Self.clicked(1))
        }
        #expect(log.prompts.map(\.title) == [String(format: DiffPageStrings.revertOneTitle, "src/upload.ts")])
        #expect(log.prompts.first?.lines == [DiffPageStrings.revertUnstagedLine, DiffPageStrings.revertTrashLine])
        #expect(git.discards.isEmpty)
        await provider.close()
    }

    @Test func eachHunkRevertsOnItsOwnEventAndUndoPutsEachBackOnce() async throws {
        let git = RecordingGit()
        git.outcome = .reverted(undo: Self.undo)
        let log = PromptLog()
        let (provider, grant, root) = try Self.provider(git, answer: false, log: log)
        defer {
            grant.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let params: JSONValue = ["paths": ["install.sh"], "scope": "unstaged", "hunk": .array(Self.hunk.map(JSONValue.string))]
        let first = try await provider.call("cmux.diff.git.discardHunk", params: params, context: Self.clicked(1))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.discardHunk", params: params, context: Self.clicked(1))
        }
        let second = try await provider.call("cmux.diff.git.discardHunk", params: params, context: Self.clicked(2))
        #expect(log.prompts.isEmpty)
        #expect(git.discards.count == 2)
        #expect(git.discards.first?.0.hunk == Self.hunk)
        let firstToken = try #require(first["undo"]?.stringValue)
        let secondToken = try #require(second["undo"]?.stringValue)
        #expect(firstToken != secondToken)

        // A token the host did not hand out puts nothing back; the page never sends the patch.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.undoDiscard", params: ["undo": "forged", "patch": "+rm -rf ~"], context: Self.clicked(3))
        }
        #expect(git.reapplied.isEmpty)

        // Both reverted hunks can come back, newest first, each once.
        _ = try await provider.call("cmux.diff.git.undoDiscard", params: ["undo": .string(secondToken)], context: Self.clicked(4))
        _ = try await provider.call("cmux.diff.git.undoDiscard", params: ["undo": .string(firstToken)], context: Self.clicked(5))
        #expect(git.reapplied.map(\.0) == [Self.undo, Self.undo])
        #expect(git.reapplied.map(\.1) == [Self.repository, Self.repository])
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.undoDiscard", params: ["undo": .string(firstToken)], context: Self.clicked(6))
        }
        #expect(git.reapplied.count == 2)
        await provider.close()
    }

    /// Undo keeps a bounded number of hunks, and none survives the tab moving to another repository.
    @Test func undoIsBoundedAndForgetsAnotherRepository() {
        var state = DiffRevertState()
        for index in 0..<(DiffRevertState.maximumUndos + 3) {
            state.push(DiffRevertUndo(token: "t\(index)", repository: "/a", undo: Self.undo))
        }
        #expect(state.undos.count == DiffRevertState.maximumUndos)
        let dropped = state.take("t0", in: "/a")
        let elsewhere = state.take("t5", in: "/b")
        let kept = state.take("t5", in: "/a")
        #expect(dropped == nil)
        #expect(elsewhere == nil)
        #expect(kept?.token == "t5")
        state.reset()
        #expect(state.undos.isEmpty)
    }

    @Test func aGitFailureReachesThePageAsGitsReason() async throws {
        let git = RecordingGit()
        git.outcome = .failed("error: patch failed: install.sh:2")
        let (provider, grant, root) = try Self.provider(git, answer: true, log: PromptLog())
        defer {
            grant.remove()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            _ = try await provider.call("cmux.diff.git.discardHunk", params: [
                "paths": ["install.sh"], "scope": "unstaged", "hunk": .array(Self.hunk.map(JSONValue.string)),
            ], context: Self.clicked(1))
            Issue.record("the revert should have failed")
        } catch let error as PageError {
            #expect(error.code == "git.failed")
            #expect(error.message == "error: patch failed: install.sh:2")
        }
        await provider.close()
    }
}
