import CmuxCollaboration
import Foundation
import Testing

@Suite(.serialized)
struct CollaborationSessionDiskTests {
    @Test
    func closeWritesResolvedTextWhenDiskBaselineIsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let descriptor = SharedFileDescriptor(repositoryID: "repo", relativePath: "note.txt", localURL: file)
        let session = CollaborationSession(peerID: "a", displayName: "A", color: "#111111", sessionID: "s")

        _ = try await session.open(file: descriptor)
        _ = try await session.applyLocalEdit(file: descriptor, range: 5..<5, replacement: " world")
        let result = try await session.close(file: descriptor)

        #expect(try String(contentsOf: file, encoding: .utf8) == "hello world")
        if case .wroteOriginal = result {} else {
            Issue.record("Expected original write, got \(result)")
        }
    }

    @Test
    func closeWritesConflictSiblingWhenDiskChangedOutOfBand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let descriptor = SharedFileDescriptor(repositoryID: "repo", relativePath: "note.txt", localURL: file)
        let session = CollaborationSession(peerID: "a", displayName: "A", color: "#111111", sessionID: "s")

        _ = try await session.open(file: descriptor)
        _ = try await session.applyLocalEdit(file: descriptor, range: 5..<5, replacement: " shared")
        try "external".write(to: file, atomically: true, encoding: .utf8)
        let result = try await session.close(file: descriptor)

        #expect(try String(contentsOf: file, encoding: .utf8) == "external")
        guard case let .wroteConflict(_, conflictURL, _, _) = result else {
            Issue.record("Expected conflict write, got \(result)")
            return
        }
        #expect(try String(contentsOf: conflictURL, encoding: .utf8) == "hello shared")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-collaboration-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
