import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceSnapshotBoundsTests {
    @Test func fileDiffRejectsContentChangedSinceStatusSnapshot() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Snapshot.swift"
        let fileURL = repo.appendingPathComponent(path)
        try Data("let value = 0\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add snapshot fixture"])
        try Data("let value = 1\n".utf8).write(to: fileURL)

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(changed.files.first { $0.path == path })

        // Preserve the same path, status, line counts, and byte length while
        // changing the content after the status snapshot.
        try Data("let value = 2\n".utf8).write(to: fileURL)

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .notFound = result else {
            Issue.record("Expected stale snapshot rejection, got \(result)")
            return
        }
    }

    @Test func fileDiffRejectsAttributesChangedSinceStatusSnapshot() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Snapshot.txt"
        let fileURL = repo.appendingPathComponent(path)
        try Data("first\nsecond\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add attributes fixture"])
        try Data("first\nchanged\n".utf8).write(to: fileURL)

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(changed.files.first { $0.path == path })

        // Change only Git's diff semantics after the row snapshot. The file,
        // index, and baseline identities remain unchanged while the same
        // content switches from a text patch to a binary diff.
        let attributes = repo.appendingPathComponent(".git/info/attributes")
        try Data("Snapshot.txt binary\n".utf8).write(to: attributes)

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .notFound = result else {
            Issue.record("Expected diff-semantics change to invalidate the status snapshot, got \(result)")
            return
        }
    }

    @Test func deletedGitlinkRowExcludesStagedDescendants() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Nested"
        let nested = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
        ] {
            try runTestGit(in: nested, arguments)
        }
        try Data("nested original\n".utf8).write(to: nested.appendingPathComponent("original.txt"))
        try runTestGit(in: nested, ["add", "--", "original.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "add nested fixture"])
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add gitlink fixture"])

        try runTestGit(in: repo, ["rm", "--quiet", "--cached", "--", path])
        try FileManager.default.removeItem(at: nested)
        let replacement = nested.appendingPathComponent("child/replacement.txt")
        try FileManager.default.createDirectory(
            at: replacement.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("replacement\n".utf8).write(to: replacement)
        try runTestGit(in: repo, ["add", "--", "Nested/child/replacement.txt"])

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(
            changed.files.first { $0.path == path && $0.status == .deleted }
        )

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .success(let diff) = result else {
            Issue.record("Expected exact deleted-gitlink diff, got \(result)")
            return
        }
        #expect(diff.unifiedDiff.contains("deleted file mode 160000"))
        #expect(!diff.unifiedDiff.contains("Nested/child/replacement.txt"))
    }

    @Test func fileDiffRejectsGitlinkTargetChangedSinceStatusSnapshot() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Nested"
        let nested = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
        ] {
            try runTestGit(in: nested, arguments)
        }
        let nestedFile = nested.appendingPathComponent("Value.txt")
        try Data("value 0\n".utf8).write(to: nestedFile)
        try runTestGit(in: nested, ["add", "--", "Value.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "nested value zero"])
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add gitlink fixture"])

        try Data("value 1\n".utf8).write(to: nestedFile)
        try runTestGit(in: nested, ["add", "--", "Value.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "nested value one"])
        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(changed.files.first { $0.path == path })

        // Move the submodule worktree to another commit with identical summary
        // counts. The parent index, baseline, and directory metadata stay fixed.
        try Data("value 2\n".utf8).write(to: nestedFile)
        try runTestGit(in: nested, ["add", "--", "Value.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "nested value two"])

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .notFound = result else {
            Issue.record("Expected submodule target change to invalidate the status snapshot, got \(result)")
            return
        }
    }

    @Test func fileDiffRejectsGitlinkDirtySinceStatusSnapshot() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Nested"
        let nested = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
        ] {
            try runTestGit(in: nested, arguments)
        }
        let nestedFile = nested.appendingPathComponent("Value.txt")
        try Data("value 0\n".utf8).write(to: nestedFile)
        try runTestGit(in: nested, ["add", "--", "Value.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "nested value zero"])
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add gitlink fixture"])

        try Data("value 1\n".utf8).write(to: nestedFile)
        try runTestGit(in: nested, ["add", "--", "Value.txt"])
        try runTestGit(in: nested, ["commit", "--quiet", "-m", "nested value one"])
        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let visible = try #require(changed.files.first { $0.path == path })

        // The parent gitlink IDs and nested HEAD stay fixed, but Git changes
        // the rendered target from the commit to that commit plus `-dirty`.
        try Data("value 2\n".utf8).write(to: nestedFile)

        let result = service.fileDiffResult(
            repoRoot: repo.path,
            path: visible.path,
            oldPath: visible.oldPath,
            status: visible.status,
            additions: visible.additions,
            deletions: visible.deletions,
            snapshotToken: visible.snapshotToken
        )
        guard case .notFound = result else {
            Issue.record("Expected submodule dirtiness to invalidate the status snapshot, got \(result)")
            return
        }
    }

    @Test func cappedStatusDropsUnverifiedUntrackedReplacement() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<120 {
            let path = "deleted-with-long-name-\(1000 + index).txt"
            try Data("original\n".utf8).write(to: repo.appendingPathComponent(path))
        }
        let replacementPath = "zzzz-replacement.txt"
        try Data("original\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add capped fixtures"])
        try runTestGit(in: repo, ["rm", "--quiet", "-r", "--", "."])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent(replacementPath))

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path, maxOutputBytes: 512))

        #expect(changed.truncated)
        #expect(!changed.files.contains { file in
            file.path == replacementPath && file.status == .untracked
        })
    }

    @Test func independentlyCappedTrackedListingsPublishOnlyCompleteRows() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<80 {
            try Data("old\n".utf8).write(
                to: repo.appendingPathComponent("tracked-with-long-name-\(1000 + index).txt")
            )
        }
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add capped tracked files"])
        for index in 0..<80 {
            try Data("new\n".utf8).write(
                to: repo.appendingPathComponent("tracked-with-long-name-\(1000 + index).txt")
            )
        }

        let changed = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path, maxOutputBytes: 512)
        )

        #expect(changed.truncated)
        #expect(!changed.files.isEmpty)
        #expect(changed.files.allSatisfy { $0.additions == 1 && $0.deletions == 1 })
    }

    @Test func cappedRawIdentityListingReturnsVerifiedTruncatedRows() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<1_750 {
            try Data("old\n".utf8).write(
                to: repo.appendingPathComponent(String(format: "f%04d", index))
            )
        }
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add raw identity fixtures"])
        for index in 0..<1_750 {
            try Data("new\n".utf8).write(
                to: repo.appendingPathComponent(String(format: "f%04d", index))
            )
        }

        let changed = try #require(
            GitDiffService().changedFiles(
                repoRoot: repo.path,
                maxOutputBytes: 16 * 1024,
                maxFiles: 400
            )
        )

        #expect(changed.truncated)
        #expect(!changed.files.isEmpty)
        #expect(changed.files.count <= 400)
        #expect(changed.files.allSatisfy { !$0.snapshotToken.isEmpty })
    }

    @Test func rowLimitBoundsReturnedSnapshotTokens() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        for index in 0..<20 {
            try Data("new\n".utf8).write(
                to: repo.appendingPathComponent("untracked-\(index).txt")
            )
        }

        let changed = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path, maxFiles: 3)
        )

        #expect(changed.files.count == 3)
        #expect(changed.files.allSatisfy { !$0.snapshotToken.isEmpty })
        #expect(changed.truncated)
    }

    @Test func configuredDiffOrderCannotExposeCappedReplacementAsUntracked() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let replacementPath = "aaaa-replacement.txt"
        try Data("original\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        for index in 0..<120 {
            let path = "zzzz-deleted-with-long-name-\(1000 + index).txt"
            try Data("original\n".utf8).write(to: repo.appendingPathComponent(path))
        }
        try runTestGit(in: repo, ["add", "--", "."])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add reordered fixtures"])
        try runTestGit(in: repo, ["rm", "--quiet", "-r", "--", "."])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent(replacementPath))
        let orderFile = repo.appendingPathComponent(".git/test-diff-order")
        try Data("zzzz*\naaaa*\n".utf8).write(to: orderFile)
        try runTestGit(in: repo, ["config", "diff.orderFile", orderFile.path])

        let changed = try #require(
            GitDiffService().changedFiles(repoRoot: repo.path, maxOutputBytes: 512)
        )

        #expect(changed.truncated)
        #expect(!changed.files.contains { file in
            file.path == replacementPath && file.status == .untracked
        })
    }

    @Test func filesystemMetadataTimeoutIsReported() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))
        let stalledStat = repo.appendingPathComponent("stalled-stat.sh")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: stalledStat)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stalledStat.path
        )
        let service = GitDiffService(
            fileSystemStatExecutableURL: stalledStat,
            processDeadlineSeconds: 0.25
        )

        guard case .timedOut = service.changedFilesResult(repoRoot: repo.path) else {
            Issue.record("Expected supervised filesystem metadata timeout")
            return
        }
    }

    @Test func filesystemMetadataBatchesStayBelowTheProcessArgumentLimit() {
        let runner = GitProcessRunner(
            gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"),
            fileSystemStatExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ProcessInfo.processInfo.environment,
            processDeadlineSeconds: 2
        )
        let longComponent = String(repeating: "nested/", count: 50)
        let paths = (0..<4_000).map { "/tmp/\(longComponent)file-\($0)" }

        let result = runner.runFileSystemStat(
            paths: paths,
            allowMissing: false,
            maxOutputBytes: 1024
        )

        #expect(result.failure == nil)
    }

    @Test func filesystemMetadataBatchesShareOneDeadline() throws {
        let stalledStat = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-batched-stat-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: stalledStat) }
        try Data("#!/bin/sh\nsleep 0.15\n".utf8).write(to: stalledStat)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stalledStat.path
        )
        let runner = GitProcessRunner(
            gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"),
            fileSystemStatExecutableURL: stalledStat,
            environment: ProcessInfo.processInfo.environment,
            processDeadlineSeconds: 0.25
        )
        let longComponent = String(repeating: "nested/", count: 50)
        let paths = (0..<4_000).map { "/tmp/\(longComponent)file-\($0)" }

        let result = runner.runFileSystemStat(
            paths: paths,
            allowMissing: false,
            maxOutputBytes: 1024
        )

        #expect(result.timedOut)
    }

    @Test func statusSnapshotRejectsWorktreeChangesBetweenListings() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = "Racing.swift"
        let fileURL = repo.appendingPathComponent(path)
        try Data("let value = 0\n".utf8).write(to: fileURL)
        try runTestGit(in: repo, ["add", "--", path])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add race fixture"])
        try Data("let value = 1\n".utf8).write(to: fileURL)
        let marker = repo.appendingPathComponent("mutation-did-run")
        let mutatingGit = repo.appendingPathComponent("mutating-git.sh")
        let script = """
        #!/bin/sh
        /usr/bin/git "$@"
        status=$?
        for argument in "$@"; do
          if [ "$argument" = "--numstat" ] && [ ! -e '\(marker.path)' ]; then
            printf 'let value = 2\\nlet other = 3\\n' > '\(fileURL.path)'
            : > '\(marker.path)'
          fi
        done
        exit "$status"
        """
        try Data(script.utf8).write(to: mutatingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mutatingGit.path
        )

        let result = GitDiffService(gitExecutableURL: mutatingGit)
            .changedFilesResult(repoRoot: repo.path)

        guard case .failed = result else {
            Issue.record("Expected a worktree race to invalidate the status snapshot")
            return
        }
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-snapshot-bounds-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            try runTestGit(in: root, arguments)
        }
        return root
    }

    private func runTestGit(in root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
