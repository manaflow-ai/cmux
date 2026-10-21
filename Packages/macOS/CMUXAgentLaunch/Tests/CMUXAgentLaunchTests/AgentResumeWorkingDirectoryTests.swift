import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentResumeWorkingDirectory")
struct AgentResumeWorkingDirectoryTests {
    @Test("Claude resumes from the worktree that owns its transcript", arguments: [false, true])
    func claudeTranscriptOverridesStaleLaunchDirectory(nested: Bool) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("repo/.claude/worktrees/feature", isDirectory: true)
        let launch = root.appendingPathComponent("repo", isDirectory: true)
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let project = root.appendingPathComponent("config/projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: runtime.path))
        let transcript = project
            .appendingPathComponent(nested ? "\(sessionID)/messages" : "", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("{}\n".utf8).write(to: transcript)
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: runtime.path,
            launchWorkingDirectory: launch.path,
            transcriptPath: transcript.path
        ) == runtime.path)
    }

    @Test("Claude uses the final projects directory in a nested transcript path")
    func claudeTranscriptUsesFinalProjectsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-final-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("repo/.claude/worktrees/feature", isDirectory: true)
        let launch = root.appendingPathComponent("repo", isDirectory: true)
        let transcript = root.appendingPathComponent("outer/projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: runtime.path))
            .appendingPathComponent("session.jsonl")
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("{}\n".utf8).write(to: transcript)
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: runtime.path,
            launchWorkingDirectory: launch.path,
            transcriptPath: transcript.path
        ) == runtime.path)
    }

    @Test("Claude project slugs preserve non-ASCII and punctuation normalization")
    func claudeTranscriptMatchesGeneralProjectSlug() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-unicode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("my_proj.v2/home/é", isDirectory: true)
        let launch = root.appendingPathComponent("a", isDirectory: true)
        let transcript = root.appendingPathComponent("config/projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: runtime.path))
            .appendingPathComponent("session.jsonl")
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("{}\n".utf8).write(to: transcript)
        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: runtime.path,
            launchWorkingDirectory: launch.path,
            transcriptPath: transcript.path
        ) == runtime.path)
    }

    @Test("Claude recovers the launch cwd from a transcript when both candidates drift")
    func claudeTranscriptRecoversRecordedWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = root.appendingPathComponent("recorded/project-é", isDirectory: true)
        let transcript = root.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: recorded.path))
            .appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record = Data("{\"cwd\":\"\(recorded.path)\"}\n".utf8)
        try record.write(to: transcript, options: .atomic)

        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: root.appendingPathComponent("runtime", isDirectory: true).path,
            launchWorkingDirectory: root.appendingPathComponent("launch", isDirectory: true).path,
            transcriptPath: transcript.path
        ) == recorded.path)
    }

    @Test("Claude skips a deleted candidate before slug matching")
    func claudeTranscriptSkipsDeletedCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-deleted-candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("project?", isDirectory: true)
        let deletedLaunch = root.appendingPathComponent("project!", isDirectory: true)
        let transcript = root.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: runtime.path))
            .appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: transcript)

        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: runtime.path,
            launchWorkingDirectory: deletedLaunch.path,
            transcriptPath: transcript.path
        ) == runtime.path)
    }

    @Test("Claude keeps complete JSONL records before an incomplete UTF-8 tail")
    func claudeTranscriptParsesCompleteLinesBeforeReadBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-utf8-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = root.appendingPathComponent("recorded/é", isDirectory: true)
        let transcript = root.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: recorded.path))
            .appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let prefix = Data("{\"cwd\":\"\(recorded.path)\"}\n".utf8)
        var contents = prefix
        contents.append(Data(repeating: 0x78, count: max(0, 65_535 - prefix.count)))
        contents.append(Data("é".utf8))
        try contents.write(to: transcript, options: .atomic)

        #expect(AgentResumeWorkingDirectory().resolve(
            kind: "claude",
            runtimeCwd: root.appendingPathComponent("runtime", isDirectory: true).path,
            launchWorkingDirectory: root.appendingPathComponent("launch", isDirectory: true).path,
            transcriptPath: transcript.path
        ) == recorded.path)
    }

    @Test("Directory-namespaced agents pin the launch cwd over a drifted runtime cwd")
    func directoryNamespacedPrefersLaunch() {
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude",
                runtimeCwd: "/Users/x/repo/worktrees/feature",
                launchWorkingDirectory: "/Users/x/repo"
            ) == "/Users/x/repo"
        )
        for kind in ["gemini", "cursor", "grok", "pi", "omp", "qoder"] {
            #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind) == .byDirectory)
            #expect(
                AgentResumeWorkingDirectory().resolve(
                    kind: kind,
                    runtimeCwd: "/Users/x/repo/sub",
                    launchWorkingDirectory: "/Users/x/repo"
                ) == "/Users/x/repo"
            )
        }
    }

    @Test("Id-keyed cwd-in-file agents keep the runtime cwd")
    func cwdInFileKeepsRuntime() {
        for kind in ["codex", "opencode", "amp", "antigravity", "rovodev", "hermes-agent"] {
            #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind) == .cwdInFile)
            #expect(
                AgentResumeWorkingDirectory().resolve(
                    kind: kind,
                    runtimeCwd: "/Users/x/repo/worktrees/feature",
                    launchWorkingDirectory: "/Users/x/repo"
                ) == "/Users/x/repo/worktrees/feature"
            )
        }
    }

    @Test("Falls back across inputs and treats empty as absent")
    func fallbacksAndEmpty() {
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: "/Users/x/repo", launchWorkingDirectory: nil
            ) == "/Users/x/repo"
        )
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: "/Users/x/repo", launchWorkingDirectory: "   "
            ) == "/Users/x/repo"
        )
        #expect(
            AgentResumeWorkingDirectory().resolve(
                kind: "claude", runtimeCwd: nil, launchWorkingDirectory: ""
            ) == nil
        )
        // Unknown kinds prefer the launch cwd (never worse for resume lookup).
        #expect(AgentResumeWorkingDirectory().cwdNamespacing(forKind: "some-future-agent") == .byDirectory)
    }
}
