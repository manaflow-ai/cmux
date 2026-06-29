import CMUXAgentLaunch
import Foundation
import Testing

@Suite("ClaudeResumeWorkingDirectory")
struct ClaudeResumeWorkingDirectoryTests {
    /// Lays down a transcript under `<home>/.claude/projects/<encoded launchCwd>/` and returns the
    /// home. The `direct` layout writes `<project>/<sessionId>.jsonl`; the nested layout writes
    /// `<project>/<sessionId>/messages/<sessionId>.jsonl` (both shapes Claude uses). When `recordCwd`
    /// is non-nil the record carries a top-level `cwd` (mirroring real transcripts).
    private func makeConfigWithTranscript(
        launchCwd: String,
        sessionId: String,
        recordCwd: String? = nil,
        nested: Bool = false
    ) throws -> (home: String, transcriptPath: String) {
        let home = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)")
        let projectDir = ((((home as NSString)
            .appendingPathComponent(".claude") as NSString)
            .appendingPathComponent("projects") as NSString)
            .appendingPathComponent(ClaudeProjectDirEncoding.projectDirName(forPath: launchCwd)))
        let transcriptDir = nested
            ? (((projectDir as NSString).appendingPathComponent(sessionId) as NSString)
                .appendingPathComponent("messages"))
            : projectDir
        try FileManager.default.createDirectory(
            atPath: transcriptDir, withIntermediateDirectories: true
        )
        let transcriptPath = (transcriptDir as NSString).appendingPathComponent("\(sessionId).jsonl")
        let line: String
        if let recordCwd {
            line = #"{"type":"user","sessionId":"\#(sessionId)","cwd":"\#(recordCwd)","message":{"role":"user","content":"hello"}}"# + "\n"
        } else {
            line = "{}\n"
        }
        try line.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        return (home, transcriptPath)
    }

    @Test("Verifies launch cwd via the transcript path when the agent drifted into a subdir")
    func verifiesViaTranscriptPath() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        let runtimeCwd = "/Users/x/repo/worktrees/feature"
        let (home, transcriptPath) = try makeConfigWithTranscript(
            launchCwd: launchCwd, sessionId: sessionId
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            claudeConfigDir: nil,
            candidateWorkingDirectories: [runtimeCwd, launchCwd] // runtime first, yet launch must win
        )
        #expect(resolved == launchCwd)
    }

    @Test("Falls back to a config-dir scan when no transcript path is reported")
    func verifiesViaConfigScanWhenTranscriptPathMissing() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        let runtimeCwd = "/Users/x/repo/sub"
        let (home, _) = try makeConfigWithTranscript(launchCwd: launchCwd, sessionId: sessionId)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: nil,
            claudeConfigDir: nil,
            candidateWorkingDirectories: [runtimeCwd, launchCwd]
        )
        #expect(resolved == launchCwd)
    }

    @Test("Honors an explicit CLAUDE_CONFIG_DIR")
    func verifiesUnderExplicitConfigDir() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        let configDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cmux-claude-cfg-\(UUID().uuidString)")
        let projectDir = (((configDir as NSString)
            .appendingPathComponent("projects") as NSString)
            .appendingPathComponent(ClaudeProjectDirEncoding.projectDirName(forPath: launchCwd)))
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let transcriptPath = (projectDir as NSString).appendingPathComponent("\(sessionId).jsonl")
        try "{}\n".write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configDir) }

        let resolved = ClaudeResumeWorkingDirectory().verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: nil,
            claudeConfigDir: configDir,
            candidateWorkingDirectories: ["/Users/x/repo/drift", launchCwd]
        )
        #expect(resolved == launchCwd)
    }

    @Test("Recovers the launch cwd from transcript content when no candidate matches")
    func recoversLaunchCwdFromTranscriptContentWhenCandidatesAllDrifted() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        // The real failure: both candidates are the drifted dir (the launch capture itself collapsed
        // to the runtime cwd), so the true launch cwd is NOT among them — but the transcript lives
        // under the launch cwd and records it in its content.
        let driftedCwd = "/Users/x/repo/worktrees/feature"
        let (home, transcriptPath) = try makeConfigWithTranscript(
            launchCwd: launchCwd, sessionId: sessionId, recordCwd: launchCwd
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            claudeConfigDir: nil,
            candidateWorkingDirectories: [driftedCwd, driftedCwd]
        )
        #expect(resolved == launchCwd)
    }

    @Test("Recovers via the nested <id>/messages/<id>.jsonl layout when candidates miss")
    func recoversFromNestedTranscriptLayout() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        let driftedCwd = "/Users/x/repo/worktrees/feature"
        let (home, transcriptPath) = try makeConfigWithTranscript(
            launchCwd: launchCwd, sessionId: sessionId, recordCwd: launchCwd, nested: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            claudeConfigDir: nil,
            candidateWorkingDirectories: [driftedCwd, driftedCwd]
        )
        #expect(resolved == launchCwd)
    }

    @Test("Ignores a transcript-recorded cwd that does not round-trip to the project dir")
    func ignoresRecordedCwdThatDoesNotRoundTrip() throws {
        let sessionId = UUID().uuidString
        let launchCwd = "/Users/x/repo"
        // Transcript stored under launchCwd's project dir, but its recorded cwd claims a different
        // path — the encoding guard must reject it rather than trust spoofed/foreign content.
        let (home, transcriptPath) = try makeConfigWithTranscript(
            launchCwd: launchCwd, sessionId: sessionId, recordCwd: "/Users/x/somewhere-else"
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            claudeConfigDir: nil,
            candidateWorkingDirectories: ["/Users/x/drift", "/Users/x/drift"]
        )
        #expect(resolved == nil)
    }

    @Test("Returns nil when neither candidate holds the transcript (caller falls back)")
    func returnsNilWhenUnverifiable() throws {
        let sessionId = UUID().uuidString
        // Transcript lives under a directory that is NOT among the candidates.
        let (home, transcriptPath) = try makeConfigWithTranscript(
            launchCwd: "/Users/x/elsewhere", sessionId: sessionId
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let resolved = ClaudeResumeWorkingDirectory(homeDirectory: home).verifiedWorkingDirectory(
            sessionId: sessionId,
            transcriptPath: transcriptPath,
            claudeConfigDir: nil,
            candidateWorkingDirectories: ["/Users/x/repo", "/Users/x/repo/sub"]
        )
        #expect(resolved == nil)
    }

    @Test("Returns nil for empty inputs")
    func returnsNilForEmptyInputs() {
        #expect(
            ClaudeResumeWorkingDirectory().verifiedWorkingDirectory(
                sessionId: "   ",
                transcriptPath: nil,
                claudeConfigDir: nil,
                candidateWorkingDirectories: ["/Users/x/repo"]
            ) == nil
        )
        #expect(
            ClaudeResumeWorkingDirectory().verifiedWorkingDirectory(
                sessionId: UUID().uuidString,
                transcriptPath: nil,
                claudeConfigDir: nil,
                candidateWorkingDirectories: []
            ) == nil
        )
    }

    @Test("Encodes both slashes and dots like Claude's project dir naming")
    func encodesDotsAndSlashes() {
        #expect(
            ClaudeProjectDirEncoding.projectDirName(forPath: "/Users/x/repo/.claude")
                == "-Users-x-repo--claude"
        )
    }
}
