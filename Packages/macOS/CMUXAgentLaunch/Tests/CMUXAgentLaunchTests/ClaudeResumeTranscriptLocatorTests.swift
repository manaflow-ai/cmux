import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Claude resume transcript lookup")
struct ClaudeResumeTranscriptLocatorTests {
    private let sessionID = "8b1f3c2e-5d4a-4e6f-9a7b-0c1d2e3f4a5b"

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-transcript-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeTranscript(
        configRoot: URL,
        project: String = "-tmp-repo",
        nested: Bool = false,
        contents: String = "{\"type\":\"user\"}\n"
    ) throws {
        var directory = configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
        if nested {
            directory = directory
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("A session started but never prompted has no transcript")
    func missingTranscript() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configRoot = home.appendingPathComponent("proxy-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configRoot.appendingPathComponent("projects/-tmp-repo", isDirectory: true),
            withIntermediateDirectories: true
        )

        let locator = ClaudeResumeTranscriptLocator(homeDirectory: home.path)
        #expect(!locator.transcriptExists(sessionId: sessionID, configuredDirectories: [configRoot.path]))
    }

    @Test("An empty transcript file is not resumable")
    func emptyTranscript() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscript(configRoot: home.appendingPathComponent(".claude"), contents: "")

        let locator = ClaudeResumeTranscriptLocator(homeDirectory: home.path)
        #expect(!locator.transcriptExists(sessionId: sessionID, configuredDirectories: []))
    }

    @Test("A transcript under the configured config directory is found")
    func configuredDirectory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configRoot = home.appendingPathComponent(".subrouter/codex/claude-proxy/abc", isDirectory: true)
        try writeTranscript(configRoot: configRoot)

        let locator = ClaudeResumeTranscriptLocator(homeDirectory: home.path)
        #expect(locator.transcriptExists(sessionId: sessionID, configuredDirectories: [configRoot.path]))
        #expect(!locator.transcriptExists(sessionId: sessionID, configuredDirectories: []))
    }

    @Test("Default roots cover ~/.claude, cmux accounts, and nested message transcripts")
    func defaultRoots() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let locator = ClaudeResumeTranscriptLocator(homeDirectory: home.path)

        try writeTranscript(configRoot: home.appendingPathComponent(".codex-accounts/claude/work"), nested: true)
        #expect(locator.transcriptExists(sessionId: sessionID, configuredDirectories: []))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex-accounts"))

        try writeTranscript(configRoot: home.appendingPathComponent(".claude"))
        #expect(locator.transcriptExists(sessionId: sessionID, configuredDirectories: []))
    }

    @Test("Path-like session ids never match a transcript")
    func unsafeSessionID() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscript(configRoot: home.appendingPathComponent(".claude"))

        let locator = ClaudeResumeTranscriptLocator(homeDirectory: home.path)
        #expect(!locator.transcriptExists(sessionId: "../\(sessionID)", configuredDirectories: []))
        #expect(!locator.transcriptExists(sessionId: "..", configuredDirectories: []))
    }
}
