@testable import CmuxMobileAgentChat
import CmuxMobileArtifacts
import Foundation
import Testing

/// A picked file over the composer's inline size is attached by its URL, with
/// no bytes. Files and Artifacts opens it from the phone; the Mac has no
/// `<cwd>/Attachments/<name>` to serve.
@Suite struct SessionArtifactsDiskAttachmentTests {
    /// The Mac's `file` service: it has no attachments folder.
    struct MacFiles: ArtifactSource {
        func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
            throw ArtifactUnavailable("asked the Mac for \(artifact.reference)")
        }
    }

    @Test func aDiskBackedAttachmentOpensFromThePhone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("build.log")
        try Data("large log".utf8).write(to: url)

        var collector = SessionArtifacts.Collector(cwd: "/Users/me/cmux")
        collector.add(AgentAttachment(kind: .file, name: "build.log", fileURL: url, byteCount: 9))
        let collected = collector.result
        let artifact = try #require(collected.artifacts.first { $0.reference == "Attachments/build.log" })

        let content = try await collected.source(fallback: MacFiles()).load(artifact)
        guard case .quickLook(let shown) = content else { Issue.record("expected the phone's file, got \(content)"); return }
        #expect(shown == url)
    }

    @Test func otherReferencesStillLoadFromTheMac() async throws {
        let collected = SessionArtifacts.Collector(cwd: "/Users/me/cmux").result
        await #expect(throws: ArtifactUnavailable("asked the Mac for Sources/main.swift")) {
            try await collected.source(fallback: MacFiles()).load(TerminalArtifact(reference: "Sources/main.swift", kind: .code))
        }
    }
}
