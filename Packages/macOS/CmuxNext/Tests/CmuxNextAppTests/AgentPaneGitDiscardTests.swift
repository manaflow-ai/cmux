@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The diff tab's Revert (D3): `git.discard` puts files back as the scope shows them (Unstaged: to
/// the index, Uncommitted: to HEAD) and moves files git does not track to the Trash; `git.discardHunk`
/// reverses one hunk in the work tree, and its Undo puts the hunk back while the file is unchanged.
/// Paths never leave the repository, a submodule is never reset, and a hunk that is not in the App's
/// own read of the diff reverts nothing. The tests pass their own Trash folder, never the real one.
@MainActor
struct AgentPaneGitDiscardTests {
    /// A repository and the folder the tests' Trash moves files into; both go when the test ends.
    final class Rig {
        let repo: String
        let bin: String
        let top: String

        init() throws {
            top = FileManager.default.temporaryDirectory.appending(path: "git-discard-\(UUID().uuidString)").path
            repo = top + "/repo"
            bin = top + "/bin"
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(atPath: top) }

        /// Moves a file into `bin`, as the Trash would.
        var trash: AgentPaneGitDiscard.Trashing {
            let bin = bin
            return { url in
                try FileManager.default.moveItem(atPath: url.path, toPath: bin + "/" + UUID().uuidString + "-" + url.lastPathComponent)
            }
        }

        /// The names of the files in `bin`, without their unique prefix.
        func binned() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: bin).map { String($0.dropFirst(37)) }.sorted()
        }

        /// The content `bin` holds for `name`.
        func binnedContent(_ name: String) throws -> String? {
            let file = try FileManager.default.contentsOfDirectory(atPath: bin).first { $0.hasSuffix("-" + name) }
            return file.flatMap { try? String(contentsOfFile: bin + "/" + $0, encoding: .utf8) }
        }
    }

    /// Twenty lines committed in `a.txt`; lines 2 and 19 changed in the work tree (two hunks),
    /// `staged.txt` changed in the index and again in the work tree, `new.txt` untracked and
    /// `added.txt` new in the index.
    private static func rig() throws -> Rig {
        let rig = try Rig()
        let repo = rig.repo
        try git(repo, "init", "-q")
        let lines = (1...20).map { "line \($0)" }
        try write(lines, repo + "/a.txt")
        try "one\n".write(toFile: repo + "/staged.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "a.txt", "staged.txt")
        try commit(repo, "one")
        var changed = lines
        changed[1] = "line two"
        changed[18] = "line nineteen"
        try write(changed, repo + "/a.txt")
        try "two\n".write(toFile: repo + "/staged.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "staged.txt")
        try "three\n".write(toFile: repo + "/staged.txt", atomically: true, encoding: .utf8)
        try "brand new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
        try "added\n".write(toFile: repo + "/added.txt", atomically: true, encoding: .utf8)
        try git(repo, "add", "added.txt")
        return rig
    }

    private static func write(_ lines: [String], _ path: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func commit(_ repo: String, _ message: String) throws {
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
    }

    @discardableResult
    private static func git(_ repo: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func revert(_ rig: Rig, _ paths: [String], scope: String, hunk: [String]? = nil,
                               trash: AgentPaneGitDiscard.Trashing? = nil) async throws -> AgentPaneGitDiscard.Outcome {
        var params: [String: Any] = ["cwd": rig.repo, "paths": paths, "scope": scope]
        if let hunk { params["hunk"] = hunk }
        let request = try #require(AgentPaneGitDiscard(method: hunk == nil ? "git.discard" : "git.discardHunk", params: params))
        return await AgentPaneGitDiscard.run(request, roots: [rig.repo], trash: trash ?? rig.trash)
    }

    /// The second hunk of `a.txt` as the diff shows it.
    private static let second = [" line 16", " line 17", " line 18", "-line 19", "+line nineteen", " line 20"]

    /// Only Unstaged and Uncommitted revert, and only paths that stay inside the repository; a hunk
    /// names one file (two for a rename) and at least one change.
    @Test func refusesRequestsThatBreakTheContract() {
        let cwd = "/tmp/repo"
        func make(_ method: String, _ params: [String: Any]) -> AgentPaneGitDiscard? {
            let base: [String: Any] = ["cwd": cwd, "scope": "unstaged"]
            return AgentPaneGitDiscard(method: method, params: base.merging(params) { _, new in new })
        }
        #expect(make("git.discard", ["paths": ["a.txt"]]) != nil)
        #expect(make("git.discard", ["paths": ["a.txt"], "scope": "uncommitted"]) != nil)
        for scope in ["staged", "branch", "committed", "lastTurn", ""] {
            #expect(make("git.discard", ["paths": ["a.txt"], "scope": scope]) == nil, "\(scope)")
        }
        for path in [".", "./", "a/..", "../a.txt", "/etc/passwd", "a//b", "a.txt/", "", "a\0b"] {
            #expect(make("git.discard", ["paths": [path]]) == nil, "\(path)")
        }
        #expect(make("git.discard", ["paths": [String]()]) == nil)
        #expect(make("git.discard", ["paths": ["a.txt", "a.txt"]]) == nil)
        #expect(make("git.discard", ["paths": (0...AgentPaneGitStage.maximumPaths).map { "f\($0)" }]) == nil)
        #expect(make("git.stage", ["paths": ["a.txt"]]) == nil)
        #expect(AgentPaneGitDiscard(method: "git.discard", params: ["cwd": "relative", "paths": ["a.txt"], "scope": "unstaged"]) == nil)
        #expect(make("git.discardHunk", ["paths": ["a.txt"], "hunk": Self.second]) != nil)
        #expect(make("git.discardHunk", ["paths": ["a.txt", "b.txt", "c.txt"], "hunk": Self.second]) == nil)
        #expect(make("git.discardHunk", ["paths": ["a.txt"], "hunk": [" line 16"]]) == nil)
        #expect(make("git.discardHunk", ["paths": ["a.txt"], "hunk": ["x"]]) == nil)
        #expect(make("git.discardHunk", ["paths": ["a.txt"]]) == nil)
    }

    /// Unstaged: a changed file gets the index's content back (its staged change stays), and an
    /// untracked file goes to the Trash.
    @Test func unstagedRevertsTheWorkTreeToTheIndex() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let outcome = try await Self.revert(rig, ["a.txt", "staged.txt", "new.txt"], scope: "unstaged")
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(Self.read(repo + "/a.txt") == (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(Self.read(repo + "/staged.txt") == "two\n")
        #expect(try Self.git(repo, "diff", "--cached", "--name-only") == "added.txt\nstaged.txt\n")
        #expect(!FileManager.default.fileExists(atPath: repo + "/new.txt"))
        #expect(try rig.binnedContent("new.txt") == "brand new\n")
        #expect(Self.read(repo + "/added.txt") == "added\n")
    }

    /// A page reload cancels its request part way through a revert: every git step still runs (restore
    /// --staged, restore --worktree, then the Trash), so the repository is never left half reverted.
    /// Before: AsyncProcess stopped git at the cancel and skipped the later steps, reported as a timeout.
    @Test func aRevertWhoseCallerIsCancelledRunsEveryStep() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try "precious\n".write(toFile: repo + "/ita.txt", atomically: true, encoding: .utf8)
        try Self.git(repo, "add", "-N", "ita.txt")
        let revert = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.revert(rig, ["a.txt", "ita.txt", "new.txt"], scope: "unstaged")
        }
        let outcome = try await revert.value
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(Self.read(repo + "/a.txt") == (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(try Self.git(repo, "ls-files", "--", "ita.txt").isEmpty)
        #expect(try rig.binned() == ["ita.txt", "new.txt"])
    }

    /// An intent-to-add file (`git add -N`) is new: Unstaged revert takes it out of the index and
    /// moves it, content and all, to the Trash. Restoring it from the index would empty it.
    @Test func unstagedRevertOfAnIntentToAddFileTrashesItsContent() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try "precious\n".write(toFile: repo + "/ita.txt", atomically: true, encoding: .utf8)
        try Self.git(repo, "add", "-N", "ita.txt")
        let outcome = try await Self.revert(rig, ["ita.txt"], scope: "unstaged")
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(!FileManager.default.fileExists(atPath: repo + "/ita.txt"))
        #expect(try rig.binnedContent("ita.txt") == "precious\n")
        #expect(try Self.git(repo, "ls-files", "--", "ita.txt").isEmpty)
    }

    /// A hunk of a new file is the whole file: a hunk revert refuses it (the file revert asks first).
    @Test func aHunkThatWouldDeleteTheFileIsRefused() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try "l1\nl2\n".write(toFile: repo + "/ita.txt", atomically: true, encoding: .utf8)
        try Self.git(repo, "add", "-N", "ita.txt")
        let outcome = try await Self.revert(rig, ["ita.txt"], scope: "unstaged", hunk: ["+l1", "+l2"])
        #expect(outcome == .failed(AgentPaneGitDiscard.wholeFileMessage), "\(outcome)")
        #expect(Self.read(repo + "/ita.txt") == "l1\nl2\n")
    }

    /// Uncommitted: the index and the work tree go back to HEAD, and a file new in the index leaves
    /// it and goes to the Trash.
    @Test func uncommittedRevertsIndexAndWorkTreeToHead() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let outcome = try await Self.revert(rig, ["staged.txt", "added.txt"], scope: "uncommitted")
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(Self.read(repo + "/staged.txt") == "one\n")
        #expect(try Self.git(repo, "diff", "--cached", "--name-only").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo + "/added.txt"))
        #expect(try rig.binnedContent("added.txt") == "added\n")
        // Files the request did not name keep their changes.
        #expect(Self.read(repo + "/new.txt") == "brand new\n")
        #expect(try Self.git(repo, "diff", "--name-only") == "a.txt\n")
    }

    /// A force-added ignored file is new in the index: Uncommitted revert moves it to the Trash too,
    /// rather than reporting success and leaving it.
    @Test func uncommittedRevertOfAForceAddedIgnoredFileTrashesIt() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try "ig\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "kept out\n".write(toFile: repo + "/ig", atomically: true, encoding: .utf8)
        try Self.git(repo, "add", "-f", "ig")
        let outcome = try await Self.revert(rig, ["ig"], scope: "uncommitted")
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(!FileManager.default.fileExists(atPath: repo + "/ig"))
        #expect(try rig.binnedContent("ig") == "kept out\n")
    }

    /// A submodule is refused before anything changes, even with `submodule.recurse` on: its
    /// checkout and its own uncommitted work stay.
    @Test func aSubmoduleIsNeverReset() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let sub = rig.top + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try Self.git(sub, "init", "-q")
        try "1\n".write(toFile: sub + "/f", atomically: true, encoding: .utf8)
        try Self.git(sub, "add", "f")
        try Self.commit(sub, "sub")
        try Self.git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "s")
        try Self.commit(repo, "with sub")
        try Self.git(repo, "config", "submodule.recurse", "true")
        try "1\nwip\n".write(toFile: repo + "/s/f", atomically: true, encoding: .utf8)
        for scope in ["unstaged", "uncommitted"] {
            let outcome = try await Self.revert(rig, ["s", "a.txt"], scope: scope)
            #expect(outcome == .failed(AgentPaneGitDiscard.submoduleMessage), "\(scope): \(outcome)")
        }
        #expect(Self.read(repo + "/s/f") == "1\nwip\n")
        #expect(Self.read(repo + "/a.txt")?.contains("line two") == true)
    }

    /// A path git does not list as untracked is never moved, even when it exists: a file in a folder
    /// that links out of the repository, and an ignored file, stay where they are.
    @Test func neverTrashesAFileGitDoesNotList() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let outside = rig.top + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "keep\n".write(toFile: outside + "/keep.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: outside)
        try "ignored\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try "secret\n".write(toFile: repo + "/ignored", atomically: true, encoding: .utf8)
        let outcome = try await Self.revert(rig, ["link/keep.txt", "ignored"], scope: "unstaged")
        #expect(outcome == .reverted(undo: nil), "\(outcome)")
        #expect(Self.read(outside + "/keep.txt") == "keep\n")
        #expect(Self.read(repo + "/ignored") == "secret\n")
        #expect(try rig.binned().isEmpty)
    }

    /// Every file is tried, and the files that did not move are named.
    @Test func aTrashFailureNamesTheFilesLeft() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try "other\n".write(toFile: repo + "/other.txt", atomically: true, encoding: .utf8)
        let refuse: AgentPaneGitDiscard.Trashing = { url in
            if url.lastPathComponent == "new.txt" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let outcome = try await Self.revert(rig, ["new.txt", "other.txt", "a.txt"], scope: "unstaged", trash: refuse)
        guard case .failed(let message) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.hasSuffix(String(format: AgentPaneGitDiscard.notRevertedMessage, "new.txt")), "\(message)")
        #expect(!FileManager.default.fileExists(atPath: repo + "/other.txt"))
        #expect(Self.read(repo + "/a.txt")?.contains("line two") == false)
    }

    /// One hunk reverts alone, its Undo puts it back, and a hunk that is not in the file's diff
    /// (stale, or edited by the page) changes nothing.
    @Test func revertsOneHunkAndUndoPutsItBack() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let outcome = try await Self.revert(rig, ["a.txt"], scope: "unstaged", hunk: Self.second)
        guard case .reverted(let undo?) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let reverted = try #require(Self.read(repo + "/a.txt"))
        #expect(reverted.contains("line two\n"))
        #expect(reverted.contains("line 19\n"))
        #expect(!reverted.contains("line nineteen"))

        let again = try await Self.revert(rig, ["a.txt"], scope: "unstaged", hunk: Self.second)
        #expect(again == .failed(AgentPaneGitStage.hunkMovedMessage))
        let edited = Self.second.map { $0 == "+line nineteen" ? "+rm -rf ~" : $0 }
        let forged = try await Self.revert(rig, ["a.txt"], scope: "unstaged", hunk: edited)
        #expect(forged == .failed(AgentPaneGitStage.hunkMovedMessage))
        #expect(Self.read(repo + "/a.txt") == reverted)

        let undone = await AgentPaneGitDiscard.reapply(undo, cwd: repo, roots: [repo])
        #expect(undone == nil, "\(undone ?? "")")
        #expect(Self.read(repo + "/a.txt")?.contains("line nineteen\n") == true)
    }

    /// Undo refuses once the file changed after the revert, so the hunk never lands in the wrong place.
    @Test func undoRefusesAfterTheFileChanged() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let outcome = try await Self.revert(rig, ["a.txt"], scope: "unstaged", hunk: Self.second)
        guard case .reverted(let undo?) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let edited = try #require(Self.read(repo + "/a.txt")) + "line 21\n"
        try edited.write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let undone = await AgentPaneGitDiscard.reapply(undo, cwd: repo, roots: [repo])
        #expect(undone == AgentPaneGitDiscard.undoChangedMessage)
        #expect(Self.read(repo + "/a.txt") == edited)
    }

    /// A hunk read with white space hidden (`git diff --ignore-all-space`, the diff tab's Hide white
    /// space) is not a hunk of the file's full diff, so it reverts nothing rather than the wrong lines.
    @Test func aHunkReadWithWhiteSpaceHiddenRevertsNothing() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        try Self.write(["a", "b", "c", "d", "e", "f", "g"], repo + "/w.txt")
        try Self.git(repo, "add", "w.txt")
        try Self.commit(repo, "two")
        try Self.write(["a", "b ", "c", "D", "e", "f", "g"], repo + "/w.txt")
        let hidden = [" a", " b ", " c", "-d", "+D", " e", " f", " g"]
        for scope in ["unstaged", "uncommitted"] {
            let outcome = try await Self.revert(rig, ["w.txt"], scope: scope, hunk: hidden)
            #expect(outcome == .failed(AgentPaneGitStage.hunkMovedMessage), "\(scope): \(outcome)")
        }
        #expect(Self.read(repo + "/w.txt") == "a\nb \nc\nD\ne\nf\ng\n")
        let full = [" a", "-b", "+b ", " c", "-d", "+D", " e", " f", " g"]
        let outcome = try await Self.revert(rig, ["w.txt"], scope: "unstaged", hunk: full)
        #expect(outcome != .failed(AgentPaneGitStage.hunkMovedMessage), "\(outcome)")
        #expect(Self.read(repo + "/w.txt") == "a\nb\nc\nd\ne\nf\ng\n")
    }

    /// Uncommitted shows HEAD against the work tree; with something staged in the file that is not
    /// the work tree's diff, so a hunk there is refused rather than half reverted.
    @Test func uncommittedHunkInAFileWithStagedChangesIsRefused() async throws {
        let rig = try Self.rig()
        let repo = rig.repo
        let staged = try await Self.revert(rig, ["staged.txt"], scope: "uncommitted", hunk: ["-one", "+three"])
        #expect(staged == .failed(AgentPaneGitDiscard.stagedHunkMessage))
        #expect(Self.read(repo + "/staged.txt") == "three\n")
        let clean = try await Self.revert(rig, ["a.txt"], scope: "uncommitted", hunk: Self.second)
        guard case .reverted = clean else {
            Issue.record("\(clean)")
            return
        }
        #expect(Self.read(repo + "/a.txt")?.contains("line nineteen") == false)
    }

    /// A folder outside the allowed roots runs nothing.
    @Test func aRepositoryOutsideTheRootsIsRefused() async throws {
        let rig = try Self.rig()
        let request = try #require(AgentPaneGitDiscard(method: "git.discard", params: ["cwd": rig.repo, "paths": ["a.txt"], "scope": "unstaged"]))
        let outcome = await AgentPaneGitDiscard.run(request, roots: ["/var/empty/elsewhere"], trash: rig.trash)
        guard case .failed = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(Self.read(rig.repo + "/a.txt")?.contains("line two") == true)
    }
}
