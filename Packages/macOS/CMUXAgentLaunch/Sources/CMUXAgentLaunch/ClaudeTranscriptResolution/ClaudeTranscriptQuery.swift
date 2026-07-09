import Foundation

/// The subset of a restorable agent's hook record that Claude transcript
/// resolution reads, lifted into a `Sendable` value so the resolution engine
/// can live in this package without depending on the app-target record type.
///
/// Build one with `RestorableAgentHookSessionRecord.claudeTranscriptQuery`
/// (app side) and pass it into ``ClaudeTranscriptResolver``.
public struct ClaudeTranscriptQuery: Sendable {
    /// The hook-reported session id (the transcript file is `<sessionId>.jsonl`).
    public var sessionId: String?
    /// The hook-reported transcript path, if the agent recorded one.
    public var transcriptPath: String?
    /// The runtime cwd reported by the hook (drifts when the agent `cd`s).
    public var cwd: String?
    /// The cwd the session was launched in (stable; matches the namespace).
    public var launchWorkingDirectory: String?
    /// The captured `CLAUDE_CONFIG_DIR`, if the launch carried one.
    public var claudeConfigDir: String?

    public init(
        sessionId: String?,
        transcriptPath: String?,
        cwd: String?,
        launchWorkingDirectory: String?,
        claudeConfigDir: String?
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.launchWorkingDirectory = launchWorkingDirectory
        self.claudeConfigDir = claudeConfigDir
    }
}
