import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitDiffServiceIdentityTests {
    @Test func undecodableUntrackedPathFailsClosed() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let blobOutput = try runTestGit(
            in: repo,
            ["hash-object", "-w", "--stdin"],
            standardInput: Data("content\n".utf8)
        )
        let blob = try #require(String(data: blobOutput, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var indexRecord = Data("100644 \(blob)\tnon-".utf8)
        indexRecord.append(0xff)
        indexRecord.append(0)
        _ = try runTestGit(
            in: repo,
            ["update-index", "-z", "--index-info"],
            standardInput: indexRecord
        )

        let service = GitDiffService()

        // Unsupported Git path bytes must not become an authoritative empty
        // repository state, which would render as "No changes" on iOS.
        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    @Test func untrackedReplacementOfRenameSourceDiffsAsAnAddition() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("original\n".utf8).write(to: repo.appendingPathComponent("A.txt"))
        try runTestGit(in: repo, ["add", "--", "A.txt"])
        try runTestGit(in: repo, ["commit", "--quiet", "-m", "add A"])
        try runTestGit(in: repo, ["mv", "--", "A.txt", "B.txt"])
        try Data("replacement\n".utf8).write(to: repo.appendingPathComponent("A.txt"))

        let service = GitDiffService()
        let changed = try #require(service.changedFiles(repoRoot: repo.path))
        let replacement = try #require(changed.files.first { $0.path == "A.txt" })
        let diff = try #require(service.fileDiff(repoRoot: repo.path, path: replacement.path))

        #expect(replacement.status == .untracked)
        #expect(diff.unifiedDiff.contains("+replacement"))
        #expect(!diff.unifiedDiff.contains("-original"))
    }

    @Test func corruptHeadDoesNotUseTheEmptyTreeBaseline() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("staged\n".utf8).write(to: repo.appendingPathComponent("staged.txt"))
        try runTestGit(in: repo, ["add", "--", "staged.txt"])
        let head = try String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8)
        let prefix = "ref: "
        let ref = try #require(head.hasPrefix(prefix) ? head.dropFirst(prefix.count) : nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refURL = repo.appendingPathComponent(".git").appendingPathComponent(ref)
        try Data("bogus\n".utf8).write(to: refURL)

        let service = GitDiffService()

        // Falling back to the empty tree here would present every indexed
        // entry as an addition even though repository state is corrupt.
        #expect(service.changedFiles(repoRoot: repo.path) == nil)
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-identity-tests-\(UUID().uuidString)")
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

    @discardableResult
    private func runTestGit(
        in root: URL,
        _ arguments: [String],
        standardInput: Data? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = standardInput.map { _ in Pipe() }
        process.standardInput = input
        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
