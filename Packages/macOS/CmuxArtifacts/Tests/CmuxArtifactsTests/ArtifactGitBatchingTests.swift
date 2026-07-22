import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git privacy batching")
struct ArtifactGitBatchingTests {
    @Test("A multi-file automatic import uses one tracked check and two ignore checks")
    func batchesGitPrivacyChecks() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let logURL = root.appendingPathComponent("git-invocations.log")
        try Data().write(to: logURL)
        let sources = try (1...3).map { index in
            try ArtifactTestSupport.write(
                "artifact \(index)",
                named: "outside/artifact-\(index).md",
                under: root
            )
        }
        let repository = LocalArtifactRepository(
            fileManager: .default,
            gitCommandRunner: ArtifactGitInvocationRecordingRunner(logURL: logURL)
        )

        let attempts = await repository.importFiles(
            candidates: sources.map { ArtifactCandidate(sourceURL: $0, provenance: .created) },
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace",
                sessionID: "session"
            ),
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(attempts.allSatisfy { attempt in
            guard case .imported(let outcome) = attempt else { return false }
            return outcome.record != nil
        })
        let invocations = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(invocations.filter { $0.contains("\u{1f}ls-files\u{1f}") }.count == 1)
        #expect(invocations.filter { $0.contains("\u{1f}check-ignore\u{1f}") }.count == 2)
        #expect(invocations.first { $0.contains("\u{1f}ls-files\u{1f}") }?
            .hasPrefix("status\u{1f}") == true)
        #expect(invocations.count == 3)
    }
}
