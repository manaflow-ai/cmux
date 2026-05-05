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
}
