import Foundation

/// Seeds a Claude Code session transcript into the project dir of a new working
/// directory before a `claude --resume <id>` launch. Claude scopes resume
/// lookups to `<config>/projects/<encoded-cwd>/`, so forking or restoring a
/// conversation into a different directory fails with "No conversation found"
/// unless the transcript is copied there first.
/// https://github.com/manaflow-ai/cmux/issues/5941
enum ClaudeSessionTranscriptSeeder {
    /// Claude Code project dir name for a working directory: the absolute path
    /// with every non-alphanumeric character replaced by `-`. Claude resolves
    /// symlinks before encoding (Node `process.cwd()`), so `/tmp/x` is stored
    /// as `-private-tmp-x`.
    static func encodedProjectDirName(forWorkingDirectory workingDirectory: String) -> String {
        ""
    }

    /// Config dirs to search for the session transcript, most specific first:
    /// the launch snapshot's captured CLAUDE_CONFIG_DIR (re-applied via `env`
    /// on resume, so it is the dir the resumed claude will actually read),
    /// then this process's CLAUDE_CONFIG_DIR, then `~/.claude`.
    static func defaultConfigDirCandidates(
        launchEnvironment: [String: String]?,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        []
    }

    /// Copies `projects/<source>/<id>.jsonl` (and the optional `<id>/` sidecar
    /// dir) into `projects/<encoded-target-cwd>/` inside the first candidate
    /// config dir that has the transcript. No-op when the target project dir
    /// already has it. Returns true when the transcript is present in the
    /// target project dir after the call.
    @discardableResult
    static func seedIfNeeded(
        sessionId: String,
        targetWorkingDirectory: String,
        configDirCandidates: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        false
    }
}
