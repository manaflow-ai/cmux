import CMUXRovoDevIndex
import Foundation
import Testing

@Suite("RovoDevIndex")
struct RovoDevIndexTests {
    @Test("Loads sessions with case-insensitive needle filtering")
    func loadsSessionsWithCaseInsensitiveNeedleFiltering() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "session with space",
            title: "Ship Rovo Dev support",
            cwd: "/tmp/rovo repo",
            modified: Date(timeIntervalSince1970: 200)
        )

        let result = RovoDevIndex.loadSessions(
            needle: "ROVO",
            cwdFilter: "/tmp/rovo repo",
            offset: 0,
            limit: 10,
            sessionsRoot: fixture.sessionsRoot.path
        )

        #expect(result.errors == [])
        #expect(result.sessions.map(\.sessionId) == ["session with space"])
        #expect(result.sessions.first?.sessionContextURL?.lastPathComponent == "session_context.json")
    }

    @Test("Reports malformed metadata")
    func reportsMalformedMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        let sessionDir = fixture.sessionsRoot.appendingPathComponent("broken-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: sessionDir.appendingPathComponent("metadata.json"))

        let result = RovoDevIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            sessionsRoot: fixture.sessionsRoot.path
        )

        #expect(result.sessions == [])
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("Rovo Dev: cannot read metadata"))
    }

    @Test("Rejects invalid pagination inputs")
    func rejectsInvalidPaginationInputs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "valid-session",
            title: "Ship Rovo Dev support",
            cwd: "/tmp/rovo repo",
            modified: Date(timeIntervalSince1970: 200)
        )

        let negativeOffset = RovoDevIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: -1,
            limit: 10,
            sessionsRoot: fixture.sessionsRoot.path
        )
        let overflow = RovoDevIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: Int.max,
            limit: 1,
            sessionsRoot: fixture.sessionsRoot.path
        )

        #expect(negativeOffset.sessions == [])
        #expect(negativeOffset.errors == [])
        #expect(overflow.sessions == [])
        #expect(overflow.errors == [])
    }

    private func makeFixture() throws -> (tempDir: URL, sessionsRoot: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-index-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempDir, sessionsRoot)
    }

    private func writeSession(
        in sessionsRoot: URL,
        id: String,
        title: String,
        cwd: String,
        modified: Date
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "title": title,
                "workspace_path": cwd,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: metadataURL.path
        )

        try Data(#"{"messages":[]}"#.utf8)
            .write(to: sessionDir.appendingPathComponent("session_context.json"))
    }
}
