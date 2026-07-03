import CMUXAgentLaunch
import Foundation
import Testing

@Suite("CodexSessionResolver")
struct CodexSessionResolverTests {
    @Test("Infers the newest rollout whose cwd matches")
    func infersNewestMatchingCwd() throws {
        let root = tempRoot("newest")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let cwd = try makeDir(root.appendingPathComponent("repo", isDirectory: true))

        try writeRollout(codexHome: codexHome, shard: "2026/06/14", sessionId: "older", cwd: cwd.path,
                         modified: Date(timeIntervalSince1970: 100))
        try writeRollout(codexHome: codexHome, shard: "2026/06/15", sessionId: "newer", cwd: cwd.path,
                         modified: Date(timeIntervalSince1970: 500))
        // Newer mtime but a different cwd: must be ignored.
        try writeRollout(codexHome: codexHome, shard: "2026/06/15", sessionId: "elsewhere",
                         cwd: root.appendingPathComponent("other", isDirectory: true).path,
                         modified: Date(timeIntervalSince1970: 900))

        let env = ["CODEX_HOME": codexHome.path]
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: cwd.path, env: env) == "newer")
    }

    @Test("Returns nil for missing or non-matching cwd")
    func rejectsMissingAndNonMatchingCwd() throws {
        let root = tempRoot("reject")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let cwd = try makeDir(root.appendingPathComponent("repo", isDirectory: true))
        try writeRollout(codexHome: codexHome, shard: "2026/06/15", sessionId: "s1", cwd: cwd.path,
                         modified: Date(timeIntervalSince1970: 200))

        let env = ["CODEX_HOME": codexHome.path]
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: nil, env: env) == nil)
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: "", env: env) == nil)
        #expect(CodexSessionResolver().inferredCodexSessionId(
            cwd: root.appendingPathComponent("nope", isDirectory: true).path, env: env) == nil)
    }

    @Test("Defaults to ~/.codex/sessions via HOME when CODEX_HOME is unset")
    func defaultsToHomeCodex() throws {
        let root = tempRoot("home")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let cwd = try makeDir(root.appendingPathComponent("repo", isDirectory: true))
        try writeRollout(codexHome: codexHome, shard: "2026/06/15", sessionId: "home-session", cwd: cwd.path,
                         modified: Date(timeIntervalSince1970: 300))

        let env = ["HOME": root.path]
        #expect(CodexSessionResolver().codexSessionsRoot(env: env)
                == codexHome.appendingPathComponent("sessions", isDirectory: true).path)
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: cwd.path, env: env) == "home-session")
    }

    @Test("Matches a symlinked cwd")
    func matchesSymlinkedCwd() throws {
        let root = tempRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let realCwd = try makeDir(root.appendingPathComponent("repo-real", isDirectory: true))
        let linkCwd = root.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkCwd, withDestinationURL: realCwd)
        // Recorded with the symlink path; resolver is queried with the real path.
        try writeRollout(codexHome: codexHome, shard: "2026/06/15", sessionId: "symlink-session", cwd: linkCwd.path,
                         modified: Date(timeIntervalSince1970: 200))

        let env = ["CODEX_HOME": codexHome.path]
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: realCwd.path, env: env) == "symlink-session")
    }

    @Test("Degrades to nil (no crash) when cwd sits past the head-read cap")
    func toleratesCwdBeyondHeadCap() throws {
        // The resolver caps the head read so a huge rollout is cheap to peek,
        // relying on codex emitting id/cwd ahead of the multi-KB base_instructions.
        // If a rollout ever pushes cwd past that cap (e.g. a future field-ordering
        // change), resolution must fail safe — return nil, never crash or hang —
        // so Fork Conversation simply hides rather than forking a wrong session.
        let root = tempRoot("beyond-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let cwd = try makeDir(root.appendingPathComponent("repo", isDirectory: true))
        let dir = codexHome.appendingPathComponent("sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A >16KB neutral field precedes cwd in the first JSONL line, so cwd falls
        // outside the head window. The padding contains no "cwd" key.
        let padding = String(repeating: "x", count: 32 * 1024)
        let firstLine = #"{"type":"session_meta","payload":{"id":"deep","base_instructions":"\#(padding)","cwd":"\#(cwd.path)"}}"#
        let fileURL = dir.appendingPathComponent("rollout-2026-06-15T00-00-00-deep.jsonl", isDirectory: false)
        try (firstLine + "\n").data(using: .utf8)!.write(to: fileURL)

        let env = ["CODEX_HOME": codexHome.path]
        #expect(CodexSessionResolver().inferredCodexSessionId(cwd: cwd.path, env: env) == nil)
    }

    // MARK: - Fixtures

    private func tempRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-resolver-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    @discardableResult
    private func makeDir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal codex rollout: a `session_meta` first line carrying
    /// `payload.id`/`payload.cwd`, plus a trailing line to mimic a real file.
    private func writeRollout(codexHome: URL, shard: String, sessionId: String, cwd: String, modified: Date) throws {
        let dir = codexHome.appendingPathComponent("sessions/\(shard)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("rollout-2026-06-15T00-00-00-\(sessionId).jsonl", isDirectory: false)
        let meta: [String: Any] = [
            "timestamp": "2026-06-15T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": sessionId,
                "timestamp": "2026-06-15T00:00:00.000Z",
                "cwd": cwd,
                "originator": "codex-tui",
            ],
        ]
        var contents = try JSONSerialization.data(withJSONObject: meta)
        contents.append(0x0A)
        contents.append(Data(#"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#.utf8))
        contents.append(0x0A)
        try contents.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
    }
}
