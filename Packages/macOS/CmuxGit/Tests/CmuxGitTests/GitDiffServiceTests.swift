import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceTests {
    @Test func mergesSeparateNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "3\t1\tSources/App.swift\0-\t-\tAssets/image.png\0",
            nameStatusOutput: "M\0Sources/App.swift\0A\0Assets/image.png\0",
            untrackedOutput: nil
        )

        #expect(files.count == 2)
        let app = try! #require(files.first { $0.path == "Sources/App.swift" })
        #expect(app.status == .modified)
        #expect(app.additions == 3)
        #expect(app.deletions == 1)

        let binary = try! #require(files.first { $0.path == "Assets/image.png" })
        #expect(binary.status == .added)
        #expect(binary.additions == nil)
        #expect(binary.deletions == nil)
    }

    @Test func mergesRenameNumstatAndNameStatusStreams() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "2\t4\t\0Old.swift\0New.swift\0",
            nameStatusOutput: "R100\0Old.swift\0New.swift\0",
            untrackedOutput: nil
        )

        let renamed = try! #require(files.first)
        #expect(files.count == 1)
        #expect(renamed.path == "New.swift")
        #expect(renamed.oldPath == "Old.swift")
        #expect(renamed.status == .renamed)
        #expect(renamed.additions == 2)
        #expect(renamed.deletions == 4)
    }

    @Test func addsUntrackedFilesWithoutCounts() {
        let service = GitDiffService()
        let files = service.parseChangedFiles(
            numstatOutput: "",
            nameStatusOutput: "",
            untrackedOutput: "Scratch.md\0"
        )

        let untracked = try! #require(files.first)
        #expect(untracked.path == "Scratch.md")
        #expect(untracked.status == .untracked)
        #expect(untracked.additions == nil)
        #expect(untracked.deletions == nil)
    }

    @Test func untrackedLeadingDashPathDiffs() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dashName = "-flag.swift"
        try Data("let flagged = true\n".utf8)
            .write(to: repo.appendingPathComponent(dashName))

        let service = GitDiffService()
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: dashName))

        #expect(diff.path == dashName)
        #expect(diff.unifiedDiff.contains("+let flagged = true"))
    }

    @Test func fileDiffOutputIsBoundedByMaxOutputBytes() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let line = "let payload = \"" + String(repeating: "x", count: 120) + "\"\n"
        let huge = String(repeating: line, count: 8_000)
        try Data(huge.utf8).write(to: repo.appendingPathComponent("Huge.swift"))

        let service = GitDiffService()
        let cap = 64 * 1024
        let diff = try #require(
            service.fileDiff(repoRoot: repo.path, path: "Huge.swift", maxOutputBytes: cap)
        )

        #expect(diff.unifiedDiff.utf8.count <= cap)
        // The bounded prefix keeps enough content for the caller's own
        // truncation detection (the full diff far exceeds the cap).
        #expect(diff.unifiedDiff.utf8.count > cap / 2)
        #expect(diff.unifiedDiff.contains("+let payload"))
    }

    @Test func fileDiffBelowMaxOutputBytesIsUnaffected() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("small change\n".utf8).write(to: repo.appendingPathComponent("Small.txt"))

        let service = GitDiffService()
        let unbounded = try #require(service.fileDiff(repoRoot: repo.path, path: "Small.txt"))
        let bounded = try #require(
            service.fileDiff(repoRoot: repo.path, path: "Small.txt", maxOutputBytes: 64 * 1024)
        )

        #expect(bounded == unbounded)
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-diff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
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
        return root
    }
}
