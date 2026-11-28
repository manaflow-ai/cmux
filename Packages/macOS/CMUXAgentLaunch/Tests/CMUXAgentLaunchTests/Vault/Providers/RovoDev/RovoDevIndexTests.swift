import CMUXAgentLaunch
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

    @Test("Sorts by session activity and accepts workspacePath metadata")
    func sortsBySessionActivityAndAcceptsWorkspacePathMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "metadata-newer",
            title: "Metadata changed",
            cwd: "/tmp/rovo repo",
            modified: Date(timeIntervalSince1970: 300),
            sessionContextModified: Date(timeIntervalSince1970: 100)
        )
        try writeSession(
            in: fixture.sessionsRoot,
            id: "conversation-newer",
            title: "Conversation changed",
            cwd: "/tmp/rovo repo",
            modified: Date(timeIntervalSince1970: 200),
            sessionContextModified: Date(timeIntervalSince1970: 400),
            workspaceKey: "workspacePath"
        )

        let result = RovoDevIndex.loadSessions(
            needle: "",
            cwdFilter: "/tmp/rovo repo",
            offset: 0,
            limit: 10,
            sessionsRoot: fixture.sessionsRoot.path
        )

        #expect(result.errors == [])
        #expect(result.sessions.map(\.sessionId) == ["conversation-newer", "metadata-newer"])
    }

    @Test("Matches cwd filter through symlinks")
    func matchesCwdFilterThroughSymlinks() throws {
        let fixture = try makeFixture()
        let workspace = fixture.tempDir.appendingPathComponent("repo-real", isDirectory: true)
        let workspaceLink = fixture.tempDir.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspaceLink, withDestinationURL: workspace)
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }

        try writeSession(
            in: fixture.sessionsRoot,
            id: "symlink-session",
            title: "Symlinked workspace",
            cwd: workspaceLink.path,
            modified: Date(timeIntervalSince1970: 200)
        )

        let result = RovoDevIndex.loadSessions(
            needle: "",
            cwdFilter: workspace.path,
            offset: 0,
            limit: 10,
            sessionsRoot: fixture.sessionsRoot.path
        )

        #expect(result.errors == [])
        #expect(result.sessions.map(\.sessionId) == ["symlink-session"])
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
            .appendingPathComponent("cmux-agent-vault-rovodev-index-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempDir, sessionsRoot)
    }

    private func writeSession(
        in sessionsRoot: URL,
        id: String,
        title: String,
        cwd: String,
        modified: Date,
        sessionContextModified: Date? = nil,
        workspaceKey: String = "workspace_path"
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "title": title,
                workspaceKey: cwd,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: metadataURL.path
        )

        let sessionContextURL = sessionDir.appendingPathComponent("session_context.json")
        try Data(#"{"messages":[]}"#.utf8).write(to: sessionContextURL)
        if let sessionContextModified {
            try FileManager.default.setAttributes(
                [.modificationDate: sessionContextModified],
                ofItemAtPath: sessionContextURL.path
            )
        }
    }
}
