import Foundation
import Testing
@testable import CmuxDockExtensions

/// End-to-end git tests against a local fixture repository over the `file://`
/// transport (the `uploadpack.*` overrides in the service make SHA fetches
/// behave like GitHub's).
@Suite("DockExtensionGitService", .serialized)
struct DockExtensionGitServiceTests {
    private struct Fixture {
        let root: URL
        let repoURL: String
        let firstSha: String
        let secondSha: String
    }

    private func git(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-git-fixture-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try git(["init", "--quiet", "--initial-branch", "main"], cwd: repo)
        _ = try git(["config", "user.email", "test@example.com"], cwd: repo)
        _ = try git(["config", "user.name", "Test"], cwd: repo)
        let manifest = """
        { "manifestVersion": 1, "id": "fixture", "name": "Fixture", "version": "1.0",
          "panes": [{ "id": "main", "title": "Fixture", "command": ["./run.sh"] }] }
        """
        try manifest.write(
            to: repo.appendingPathComponent(DockExtensionManifest.manifestFileName),
            atomically: true, encoding: .utf8
        )
        _ = try git(["add", "."], cwd: repo)
        _ = try git(["commit", "--quiet", "-m", "first"], cwd: repo)
        let firstSha = try git(["rev-parse", "HEAD"], cwd: repo)
        try "update".write(to: repo.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], cwd: repo)
        _ = try git(["commit", "--quiet", "-m", "second"], cwd: repo)
        _ = try git(["tag", "v1"], cwd: repo)
        let secondSha = try git(["rev-parse", "HEAD"], cwd: repo)
        return Fixture(root: root, repoURL: "file://\(repo.path)", firstSha: firstSha, secondSha: secondSha)
    }

    @Test func resolvesHeadBranchTagAndSha() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DockExtensionGitService()

        #expect(try await service.resolveRemoteRevision(cloneURL: fixture.repoURL, ref: nil) == fixture.secondSha)
        #expect(try await service.resolveRemoteRevision(cloneURL: fixture.repoURL, ref: "main") == fixture.secondSha)
        #expect(try await service.resolveRemoteRevision(cloneURL: fixture.repoURL, ref: "v1") == fixture.secondSha)
        #expect(try await service.resolveRemoteRevision(cloneURL: fixture.repoURL, ref: fixture.firstSha) == fixture.firstSha)

        await #expect(throws: DockExtensionError.self) {
            _ = try await service.resolveRemoteRevision(cloneURL: fixture.repoURL, ref: "no-such-branch")
        }
    }

    @Test func materializesDetachedCheckoutAtPinnedSha() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DockExtensionGitService()
        let checkout = fixture.root.appendingPathComponent("checkout", isDirectory: true)

        // Pin to the FIRST commit even though the remote has moved on.
        try await service.materializeCheckout(cloneURL: fixture.repoURL, sha: fixture.firstSha, into: checkout)
        let manifestPath = checkout.appendingPathComponent(DockExtensionManifest.manifestFileName).path
        #expect(FileManager.default.fileExists(atPath: manifestPath))
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("extra.txt").path))
        #expect(try git(["rev-parse", "HEAD"], cwd: checkout) == fixture.firstSha)

        // Re-materializing over the same directory (update) lands on the new pin.
        try await service.materializeCheckout(cloneURL: fixture.repoURL, sha: fixture.secondSha, into: checkout)
        #expect(try git(["rev-parse", "HEAD"], cwd: checkout) == fixture.secondSha)
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("extra.txt").path))
    }

    @Test func picksRevisionsByPreference() {
        let sha1 = String(repeating: "1", count: 40)
        let sha2 = String(repeating: "2", count: 40)
        let sha3 = String(repeating: "3", count: 40)
        let output = """
        \(sha1)\trefs/tags/v1
        \(sha2)\trefs/tags/v1^{}
        \(sha3)\trefs/heads/v1
        """
        #expect(DockExtensionGitService.pickRevision(from: output, ref: "v1") == sha3)
        let tagsOnly = """
        \(sha1)\trefs/tags/v1
        \(sha2)\trefs/tags/v1^{}
        """
        #expect(DockExtensionGitService.pickRevision(from: tagsOnly, ref: "v1") == sha2)
        #expect(DockExtensionGitService.pickRevision(from: "\(sha1)\tHEAD", ref: nil) == sha1)
        #expect(DockExtensionGitService.pickRevision(from: "", ref: nil) == nil)
    }

    @Test func recognizesFullShas() {
        #expect(DockExtensionGitService.isFullSha(String(repeating: "a", count: 40)))
        #expect(DockExtensionGitService.isFullSha(String(repeating: "A", count: 40)))
        #expect(!DockExtensionGitService.isFullSha("main"))
        #expect(!DockExtensionGitService.isFullSha(String(repeating: "g", count: 40)))
        #expect(!DockExtensionGitService.isFullSha(String(repeating: "a", count: 39)))
    }
}
