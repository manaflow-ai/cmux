@testable import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing

/// A picked file too large to hold keeps its URL (no copy of its bytes), and
/// Files only lets the app read it inside its security scope. The preview
/// opens that scope before Quick Look or the player reads the file, holds it
/// while the preview is open, and closes it when the preview closes.
@Suite struct LocalFileScopeTests {
    /// Counts the scope's starts and stops (the system's needs a real Files pick).
    final class PreviewScope: SecurityScope, @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var stopped = 0

        var starts: Int { lock.withLock { started } }
        var stops: Int { lock.withLock { stopped } }

        func startAccessing(_ url: URL) -> Bool {
            lock.withLock { started += 1 }
            return true
        }

        func stopAccessing(_ url: URL) {
            lock.withLock { stopped += 1 }
        }
    }

    static func pickedFile(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    @Test func aPickedDocumentPreviewHoldsItsScopeUntilThePreviewCloses() async throws {
        let url = try Self.pickedFile("Quarterly Report.docx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = LocalFile(id: "p", name: "Quarterly Report.docx", data: nil, isImage: false, fileURL: url)
        let scope = PreviewScope()

        do {
            let source = LocalFileArtifactSource(files: [file], scope: scope)
            guard case .quickLook(let shown) = try await source.load(file.artifact) else { Issue.record("quickLook"); return }
            // Quick Look reads the picked file itself, inside the open scope.
            #expect(shown == url)
            #expect(scope.starts == 1)
            #expect(scope.stops == 0)
            // Try Again loads it again: the same access, not a second one.
            _ = try await source.load(file.artifact)
            #expect(scope.starts == 1)
            #expect(scope.stops == 0)
            withExtendedLifetime(source) {}
        }

        // The preview closed (its source released): the scope closes.
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    @Test func aPickedVideoStaysInScopeForThePlayer() async throws {
        let url = try Self.pickedFile("clip.mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = LocalFile(id: "v", name: "clip.mov", data: nil, isImage: false, fileURL: url)
        let scope = PreviewScope()

        do {
            let source = LocalFileArtifactSource(files: [file], scope: scope)
            guard case .file(let played) = try await source.load(file.artifact) else { Issue.record("video"); return }
            #expect(played == url)
            #expect(scope.starts == 1)
            #expect(scope.stops == 0)
            withExtendedLifetime(source) {}
        }

        #expect(scope.stops == 1)
    }

    /// A picked file that is gone: the preview says so and its scope closes at once.
    @Test func aMissingPickedFileClosesItsScopeAndSaysSo() async {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-gone.pdf")
        let file = LocalFile(id: "g", name: "gone.pdf", data: nil, isImage: false, fileURL: gone)
        let scope = PreviewScope()
        let source = LocalFileArtifactSource(files: [file], scope: scope)

        await #expect(throws: ArtifactUnavailable.self) { try await source.load(file.artifact) }

        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
        withExtendedLifetime(source) {}
    }

    /// Bytes the phone holds open no scope.
    @Test func bytesHeldInMemoryOpenNoScope() async throws {
        let file = LocalFile(id: "b", name: "notes.txt", data: Data("one".utf8), isImage: false)
        let scope = PreviewScope()
        let source = LocalFileArtifactSource(files: [file], scope: scope)

        guard case .text("one") = try await source.load(file.artifact) else { Issue.record("text"); return }
        #expect(scope.starts == 0)
    }
}
