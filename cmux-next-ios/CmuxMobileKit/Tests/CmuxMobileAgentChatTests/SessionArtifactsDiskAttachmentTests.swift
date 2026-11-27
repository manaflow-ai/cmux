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

        // A small text file previews as text, read from the phone's file.
        let content = try await collected.source(fallback: MacFiles()).load(artifact)
        guard case .text(let text) = content else { Issue.record("expected the phone's file, got \(content)"); return }
        #expect(text == "large log")
    }

    /// Two attachments of one name: the newer one opens, bytes or file.
    @Test func theNewerAttachmentOfANameOpens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("build.log")
        try Data("large log".utf8).write(to: url)
        let small = AgentAttachment(kind: .file, name: "build.log", data: Data("small log".utf8))
        let large = AgentAttachment(kind: .file, name: "build.log", fileURL: url, byteCount: 9)

        var smallThenLarge = SessionArtifacts.Collector(cwd: "/Users/me/cmux")
        smallThenLarge.add(small)
        smallThenLarge.add(large)
        let newerFile = try await Self.open("Attachments/build.log", in: smallThenLarge.result)
        guard case .text(let fromFile) = newerFile else { Issue.record("expected the newer file, got \(newerFile)"); return }
        #expect(fromFile == "large log")

        var largeThenSmall = SessionArtifacts.Collector(cwd: "/Users/me/cmux")
        largeThenSmall.add(large)
        largeThenSmall.add(small)
        let newerBytes = try await Self.open("Attachments/build.log", in: largeThenSmall.result)
        guard case .text(let text) = newerBytes else { Issue.record("expected the newer bytes, got \(newerBytes)"); return }
        #expect(text == "small log")
    }

    /// A newer attachment of a name takes its kind too: an image then a file opens as the file.
    @Test func theNewerAttachmentOfANameTakesItsKind() throws {
        let image = AgentAttachment(kind: .image, name: "shot", data: Data([0x89, 0x50]))
        let file = AgentAttachment(kind: .file, name: "shot", data: Data("notes".utf8))
        var collector = SessionArtifacts.Collector(cwd: "/Users/me/cmux")
        collector.add(image)
        collector.add(file)
        let artifact = try #require(collector.result.artifacts.first { $0.reference == "Attachments/shot" })
        #expect(artifact.kind != .image)
    }

    static func open(_ reference: String, in collected: SessionArtifacts) async throws -> ArtifactContent {
        let artifact = try #require(collected.artifacts.first { $0.reference == reference })
        return try await collected.source(fallback: MacFiles()).load(artifact)
    }

    @Test func otherReferencesStillLoadFromTheMac() async throws {
        let collected = SessionArtifacts.Collector(cwd: "/Users/me/cmux").result
        await #expect(throws: ArtifactUnavailable("asked the Mac for Sources/main.swift")) {
            try await collected.source(fallback: MacFiles()).load(TerminalArtifact(reference: "Sources/main.swift", kind: .code))
        }
    }
}
