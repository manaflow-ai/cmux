import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceInputBoundaryTests {
    @Test func trackedDirectoryShapedFileDiffRequestIsRejected() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let directory = repo.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracked = directory.appendingPathComponent("Tracked.swift")
        try Data("original\n".utf8).write(to: tracked)
        try runTestGit(in: repo, ["add", "--", "Sources/Tracked.swift"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add tracked child"])
        try Data("changed\n".utf8).write(to: tracked)

        let service = GitDiffService()

        #expect(service.fileDiff(repoRoot: repo.path, path: "Sources") == nil)
        #expect(service.fileDiff(repoRoot: repo.path, path: ".") == nil)
    }

    @Test func ambientShellStartupEnvironmentIsScrubbedBeforeWrapperLaunch() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let checkingGit = repo.appendingPathComponent("checking-git.sh")
        try Data(
            "#!/bin/sh\nif [ -n \"$BASH_ENV$ENV\" ]; then exit 91; fi\nexec /usr/bin/git \"$@\"\n".utf8
        ).write(to: checkingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: checkingGit.path
        )
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("visible.txt"))

        var environment = ProcessInfo.processInfo.environment
        environment["BASH_ENV"] = "/path/that/does/not/exist"
        environment["ENV"] = "/path/that/does/not/exist"
        environment["SHELLOPTS"] = "checkwinsize"
        environment["BASHOPTS"] = "checkwinsize"
        let service = GitDiffService(gitExecutableURL: checkingGit, environment: environment)

        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        #expect(changed.files.map(\.path) == ["checking-git.sh", "visible.txt"])
    }

    @Test func renamedFileDiffIncludesSourceAndDestination() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("unchanged content\n".utf8).write(to: repo.appendingPathComponent("Old.swift"))
        try runTestGit(in: repo, ["add", "--", "Old.swift"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add old path"])
        try runTestGit(in: repo, ["mv", "--", "Old.swift", "New.swift"])

        let service = GitDiffService()
        let diff = try #require(
            service.fileDiff(repoRoot: repo.path, path: "New.swift", oldPath: "Old.swift")
        )

        #expect(diff.unifiedDiff.contains("rename from Old.swift"))
        #expect(diff.unifiedDiff.contains("rename to New.swift"))
        #expect(!diff.unifiedDiff.contains("new file mode"))
    }

    @Test func staleRenameSourceCannotReturnMultipleFileSections() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let oldFile = repo.appendingPathComponent("Old.swift")
        try Data("original\n".utf8).write(to: oldFile)
        try runTestGit(in: repo, ["add", "--", "Old.swift"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add old path"])
        try runTestGit(in: repo, ["mv", "--", "Old.swift", "New.swift"])
        try Data("unrelated current edit\n".utf8).write(to: oldFile)
        try runTestGit(in: repo, ["add", "--", "Old.swift"])

        let service = GitDiffService()

        #expect(service.fileDiff(repoRoot: repo.path, path: "New.swift", oldPath: "Old.swift") == nil)
    }

    @Test func renameSourceCannotExpandToARepositoryDirectory() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("Tracked.swift")
        try Data("original\n".utf8).write(to: file)
        try runTestGit(in: repo, ["add", "--", "Tracked.swift"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add tracked file"])
        try Data("changed\n".utf8).write(to: file)

        let service = GitDiffService()

        #expect(service.fileDiff(repoRoot: repo.path, path: "Tracked.swift", oldPath: ".") == nil)
    }

    @Test func deletedBaselineDirectoryCannotExpandToDescendants() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let directory = repo.appendingPathComponent("Deleted")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: directory.appendingPathComponent("One.txt"))
        try Data("two\n".utf8).write(to: directory.appendingPathComponent("Two.txt"))
        try runTestGit(in: repo, ["add", "--", "Deleted"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add directory"])
        try FileManager.default.removeItem(at: directory)

        let service = GitDiffService()

        #expect(service.fileDiff(repoRoot: repo.path, path: "Deleted") == nil)
    }

    @Test func exactFileReplacingBaselineDirectoryDiffsWithoutDescendants() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let directory = repo.appendingPathComponent("Replaced")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old child\n".utf8).write(to: directory.appendingPathComponent("Child.txt"))
        try runTestGit(in: repo, ["add", "--", "Replaced/Child.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add directory"])
        try FileManager.default.removeItem(at: directory)
        try Data("replacement file\n".utf8).write(to: directory)
        try runTestGit(in: repo, ["add", "-A", "--", "Replaced"])

        let diff = try #require(GitDiffService().fileDiff(repoRoot: repo.path, path: "Replaced"))

        #expect(diff.unifiedDiff.contains("+replacement file"))
        #expect(!diff.unifiedDiff.contains("old child"))
        #expect(!diff.unifiedDiff.contains("Child.txt"))
    }

    @Test func baselineFileReplacedByDirectoryDiffsWithoutDescendants() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let replaced = repo.appendingPathComponent("node")
        try Data("old file\n".utf8).write(to: replaced)
        try runTestGit(in: repo, ["add", "--", "node"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add file"])
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: true)
        try Data("new child\n".utf8).write(to: replaced.appendingPathComponent("child.txt"))
        try runTestGit(in: repo, ["add", "-A", "--", "node"])

        let diff = try #require(GitDiffService().fileDiff(repoRoot: repo.path, path: "node"))

        #expect(diff.unifiedDiff.contains("-old file"))
        #expect(!diff.unifiedDiff.contains("new child"))
        #expect(!diff.unifiedDiff.contains("child.txt"))
    }

    @Test func untrackedFileReplacingBaselineDirectoryDiffsWithoutDescendants() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let directory = repo.appendingPathComponent("Replaced")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old child\n".utf8).write(to: directory.appendingPathComponent("Child.txt"))
        try runTestGit(in: repo, ["add", "--", "Replaced/Child.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add directory"])
        try FileManager.default.removeItem(at: directory)
        try Data("replacement file\n".utf8).write(to: directory)

        let diff = try #require(GitDiffService().fileDiff(repoRoot: repo.path, path: "Replaced"))

        #expect(diff.unifiedDiff.contains("+replacement file"))
        #expect(!diff.unifiedDiff.contains("old child"))
        #expect(!diff.unifiedDiff.contains("Child.txt"))
    }

    @Test func nonUTF8TextDiffUsesReplacementCharacters() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("Latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: file)
        try runTestGit(in: repo, ["add", "--", "Latin1.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add latin1 text"])
        try Data([0x63, 0x61, 0x66, 0xE8, 0x0A]).write(to: file)

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: "Latin1.txt"))

        #expect(diff.unifiedDiff.contains("�"))
    }

    @Test func invalidUTF8PathIsOmittedWithoutCollapsingIdentity() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("valid\n".utf8).write(to: repo.appendingPathComponent("valid.txt"))
        let blobOutput = try runTestGit(
            in: repo,
            ["hash-object", "-w", "--stdin"],
            standardInput: Data("unsupported path\n".utf8)
        )
        let blob = try #require(String(data: blobOutput, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var indexRecord = Data("100644 \(blob)\tinvalid-".utf8)
        indexRecord.append(0xFF)
        indexRecord.append(Data(".txt\0".utf8))
        _ = try runTestGit(
            in: repo,
            ["update-index", "-z", "--index-info"],
            standardInput: indexRecord
        )

        let changed = try #require(GitDiffService().changedFiles(repoRoot: repo.path))

        #expect(changed.files.map(\.path) == ["valid.txt"])
        #expect(!changed.files.contains { $0.path.contains("�") })
    }

    @Test func symlinkToDirectoryRemainsOneDiffableFile() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("TargetA"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("TargetB"),
            withIntermediateDirectories: true
        )
        let link = repo.appendingPathComponent("Current")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "TargetA")
        try runTestGit(in: repo, ["add", "--", "Current"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add directory symlink"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "TargetB")

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: "Current"))

        #expect(diff.unifiedDiff.contains("-TargetA"))
        #expect(diff.unifiedDiff.contains("+TargetB"))
    }

    @Test func deletedPathWithUntrackedReplacementKeepsDeletedDiff() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("replaced.txt")
        try Data("original\n".utf8).write(to: file)
        try runTestGit(in: repo, ["add", "--", "replaced.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add original"])
        try runTestGit(in: repo, ["rm", "--cached", "--quiet", "--", "replaced.txt"])
        try Data("replacement\n".utf8).write(to: file)

        let service = GitDiffService()
        let status = try #require(service.changedFiles(repoRoot: repo.path))
        let summary = try #require(status.files.first { $0.path == "replaced.txt" })
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: "replaced.txt"))

        #expect(summary.status == .deleted)
        #expect(diff.unifiedDiff.contains("-original"))
        #expect(!diff.unifiedDiff.contains("+replacement"))
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-boundary-tests-\(UUID().uuidString)")
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

    private func runTestGit(
        in root: URL,
        _ arguments: [String],
        standardInput: Data
    ) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: standardInput)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return data
    }
}
