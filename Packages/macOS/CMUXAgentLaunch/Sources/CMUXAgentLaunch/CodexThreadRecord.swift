public import Foundation

/// One decoded row of Codex's `state_5.sqlite` `threads` table, carrying the
/// fields Codex pre-extracts per session (cwd, title, model, branch, approval,
/// sandbox, effort, rollout path, update time).
///
/// A pure `Sendable` value: it is what ``CodexThreadSQLResolver`` returns, and
/// the app maps it onto its own session-entry type. The resolver never builds a
/// session-entry from this; the field-to-display mapping stays app-side.
public struct CodexThreadRecord: Sendable {
    /// The Codex session id (`threads.id`).
    public let sessionId: String
    /// The rollout `.jsonl` path Codex recorded for this thread.
    public let rolloutPath: String
    /// The recorded working directory, or `nil` when Codex stored none.
    public let cwd: String?
    /// The pre-extracted thread title (may be empty).
    public let titleField: String
    /// The model id, or `nil`.
    public let model: String?
    /// The git branch recorded at session start, or `nil`.
    public let gitBranch: String?
    /// The approval mode, or `nil`.
    public let approvalMode: String?
    /// The raw `sandbox_policy` JSON string, or `nil`.
    public let sandboxJSON: String?
    /// The reasoning-effort label, or `nil`.
    public let reasoningEffort: String?
    /// The first user message recorded for the thread (may be empty).
    public let firstUserMessage: String
    /// The thread's last-updated time, in milliseconds since the Unix epoch.
    public let updatedMs: Int64

    /// Creates a record from decoded column values.
    public init(
        sessionId: String,
        rolloutPath: String,
        cwd: String?,
        titleField: String,
        model: String?,
        gitBranch: String?,
        approvalMode: String?,
        sandboxJSON: String?,
        reasoningEffort: String?,
        firstUserMessage: String,
        updatedMs: Int64
    ) {
        self.sessionId = sessionId
        self.rolloutPath = rolloutPath
        self.cwd = cwd
        self.titleField = titleField
        self.model = model
        self.gitBranch = gitBranch
        self.approvalMode = approvalMode
        self.sandboxJSON = sandboxJSON
        self.reasoningEffort = reasoningEffort
        self.firstUserMessage = firstUserMessage
        self.updatedMs = updatedMs
    }

    /// The symlink-/tilde-standardized rollout path, or `nil` when the recorded
    /// path is blank.
    public var normalizedRolloutPath: String? {
        let trimmed = rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).standardizingPath
    }
}
