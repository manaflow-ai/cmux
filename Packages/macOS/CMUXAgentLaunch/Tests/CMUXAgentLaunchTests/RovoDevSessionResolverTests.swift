import CMUXAgentLaunch
import Foundation
import Testing

@Suite("RovoDevSessionResolver")
struct RovoDevSessionResolverTests {
    @Test("Reads direct sessions persistenceDir with CRLF comments and single-quoted apostrophes")
    func readsDirectSessionsPersistenceDir() {
        let config = [
            "sessions:",
            "  # keep comments inside the sessions block",
            "  nested:",
            "    persistenceDir: /tmp/wrong",
            "# top-level comments do not end the block",
            "  persistenceDir: '~/sessions#john''s'",
            "other: true",
        ].joined(separator: "\r\n")

        #expect(RovoDevSessionResolver.rovoDevPersistenceDir(fromConfig: config) == "~/sessions#john's")
    }

    @Test("Does not match Rovo sessions without an exact cwd")
    func rejectsMissingAndNonExactCwd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-resolver-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let sessionURL = sessionsRoot.appendingPathComponent("rovo-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let metadata = [
            "workspace_path": root.appendingPathComponent("repo", isDirectory: true).path,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: sessionURL.appendingPathComponent("metadata.json", isDirectory: false))
        defer { try? FileManager.default.removeItem(at: root) }

        let env = ["CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path]
        #expect(RovoDevSessionResolver.inferredRovoDevSessionId(cwd: nil, env: env) == nil)
        #expect(RovoDevSessionResolver.inferredRovoDevSessionId(cwd: "", env: env) == nil)
        #expect(RovoDevSessionResolver.inferredRovoDevSessionId(cwd: root.path, env: env) == nil)
    }

    @Test("Infers newest matching workspace session")
    func infersNewestMatchingWorkspaceSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-resolver-newest-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "older-session",
            workspacePath: workspace.path,
            metadataModified: Date(timeIntervalSince1970: 300),
            sessionContextModified: Date(timeIntervalSince1970: 100)
        )
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "newer-session",
            workspacePath: workspace.path,
            metadataModified: Date(timeIntervalSince1970: 200),
            sessionContextModified: Date(timeIntervalSince1970: 400),
            workspaceKey: "workspacePath"
        )

        let env = ["CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path]
        #expect(RovoDevSessionResolver.inferredRovoDevSessionId(cwd: workspace.path, env: env) == "newer-session")
    }

    @Test("Matches symlinked workspace paths")
    func matchesSymlinkedWorkspacePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovo-resolver-symlink-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo-real", isDirectory: true)
        let workspaceLink = root.appendingPathComponent("repo-link", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspaceLink, withDestinationURL: workspace)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "symlink-session",
            workspacePath: workspaceLink.path,
            metadataModified: Date(timeIntervalSince1970: 200),
            sessionContextModified: Date(timeIntervalSince1970: 200)
        )

        let env = ["CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path]
        #expect(RovoDevSessionResolver.inferredRovoDevSessionId(cwd: workspace.path, env: env) == "symlink-session")
    }

    private func writeSession(
        sessionsRoot: URL,
        sessionId: String,
        workspacePath: String,
        metadataModified: Date,
        sessionContextModified: Date,
        workspaceKey: String = "workspace_path"
    ) throws {
        let sessionURL = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let metadataURL = sessionURL.appendingPathComponent("metadata.json", isDirectory: false)
        let metadata = [
            "title": "Rovo Dev session",
            workspaceKey: workspacePath,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: metadataURL)
        try FileManager.default.setAttributes([.modificationDate: metadataModified], ofItemAtPath: metadataURL.path)

        let sessionContextURL = sessionURL.appendingPathComponent("session_context.json", isDirectory: false)
        try Data(#"{"message_history":[]}"#.utf8).write(to: sessionContextURL)
        try FileManager.default.setAttributes(
            [.modificationDate: sessionContextModified],
            ofItemAtPath: sessionContextURL.path
        )
    }
}
