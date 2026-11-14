import Foundation
import Testing

@testable import CMUXAgentLaunch

@Suite("CursorSessionIndex")
struct CursorSessionIndexTests {
    @Test("Searches transcript content and merges hook cwd metadata")
    func searchesTranscriptContentAndMergesHookMetadata() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let transcriptURL = try writeTranscript(
            projectsRoot: fixture.projectsRoot,
            project: "workspace-slug",
            sessionID: "cursor-session-123",
            lines: [
                #"{"role":"user","message":{"content":[{"type":"text","text":"Index Cursor sessions"}]}}"#,
                #"{"role":"assistant","message":{"content":[{"type":"text","text":"The cobalt needle is in the transcript."}]}}"#,
            ],
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try writeHookStore(
            at: fixture.hookStoreURL,
            sessions: [
                "cursor-session-123": [
                    "sessionId": "cursor-session-123",
                    "cwd": "/tmp/cursor repo",
                    "updatedAt": 200.0,
                ],
            ]
        )

        let index = CursorSessionIndex(
            projectsRoot: fixture.projectsRoot,
            hookStoreURL: fixture.hookStoreURL
        )
        let result = await index.loadSessions(
            needle: "COBALT NEEDLE",
            workingDirectoryFilter: "/tmp/cursor repo",
            offset: 0,
            limit: 10
        )

        #expect(result.errors == [])
        let session = try #require(result.sessions.first)
        #expect(result.sessions.count == 1)
        #expect(session.sessionID == "cursor-session-123")
        #expect(session.title == "Index Cursor sessions")
        #expect(session.workingDirectory == "/tmp/cursor repo")
        #expect(session.modifiedAt == Date(timeIntervalSince1970: 200))
        #expect(session.transcriptURL == transcriptURL.standardizedFileURL)
    }

    @Test("Uses a hook title when a transcript has no user message")
    func usesHookTitleFallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try writeTranscript(
            projectsRoot: fixture.projectsRoot,
            project: "workspace-slug",
            sessionID: "assistant-only",
            lines: [
                #"{"role":"assistant","message":{"content":[{"type":"text","text":"Finished."}]}}"#,
            ],
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        try writeHookStore(
            at: fixture.hookStoreURL,
            sessions: [
                "assistant-only": [
                    "sessionId": "assistant-only",
                    "title": "Recovered Cursor title",
                    "updatedAt": 100.0,
                ],
                "malformed-record": "ignored",
            ]
        )

        let index = CursorSessionIndex(
            projectsRoot: fixture.projectsRoot,
            hookStoreURL: fixture.hookStoreURL
        )
        let result = await index.loadSessions(
            needle: "recovered cursor",
            workingDirectoryFilter: nil,
            offset: 0,
            limit: 10
        )

        #expect(result.errors == [])
        #expect(result.sessions.map(\.title) == ["Recovered Cursor title"])
    }

    @Test("Sorts stably and applies pagination after filtering")
    func sortsStablyAndPaginatesMatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for sessionID in ["session-b", "session-a", "unmatched"] {
            try writeTranscript(
                projectsRoot: fixture.projectsRoot,
                project: "workspace-slug",
                sessionID: sessionID,
                lines: [
                    #"{"role":"user","message":{"content":[{"type":"text","text":"\#(sessionID) matching title"}]}}"#,
                ],
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
        }

        let index = CursorSessionIndex(
            projectsRoot: fixture.projectsRoot,
            hookStoreURL: nil
        )
        let result = await index.loadSessions(
            needle: "matching",
            workingDirectoryFilter: nil,
            offset: 1,
            limit: 1
        )

        #expect(result.errors == [])
        #expect(result.sessions.map(\.sessionID) == ["session-b"])
    }

    @Test("Reports unreadable transcript data without exposing paths")
    func reportsUnreadableTranscript() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "invalid-utf8"
        let transcriptURL = fixture.projectsRoot
            .appendingPathComponent("workspace-slug", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xff, 0xfe]).write(to: transcriptURL)

        let index = CursorSessionIndex(
            projectsRoot: fixture.projectsRoot,
            hookStoreURL: fixture.hookStoreURL
        )
        let result = await index.loadSessions(
            needle: "",
            workingDirectoryFilter: nil,
            offset: 0,
            limit: 10
        )

        #expect(result.sessions == [])
        #expect(result.errors == [.transcriptUnreadable])
    }

    private func makeFixture() throws -> (
        root: URL,
        projectsRoot: URL,
        hookStoreURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-agent-launch-cursor-index-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let hookStoreURL = root.appendingPathComponent(
            "cursor-hook-sessions.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: projectsRoot,
            withIntermediateDirectories: true
        )
        return (root, projectsRoot, hookStoreURL)
    }

    @discardableResult
    private func writeTranscript(
        projectsRoot: URL,
        project: String,
        sessionID: String,
        lines: [String],
        modifiedAt: Date
    ) throws -> URL {
        let transcriptURL = projectsRoot
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: transcriptURL.path
        )
        return transcriptURL
    }

    private func writeHookStore(
        at url: URL,
        sessions: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: url)
    }
}
