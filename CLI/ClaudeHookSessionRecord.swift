import Foundation

struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var title: String? = nil
    var transcriptPath: String?
    var pid: Int?
    /// Exact process-generation identity captured when the hook recorded `pid`.
    var pidStartSeconds: Int64? = nil
    var pidStartMicroseconds: Int64? = nil
    /// Recent process generations retained so a delayed SessionEnd can be
    /// matched after a same-session resume updates the current PID.
    var priorProcessGenerations: [ClaudeHookProcessGeneration]? = nil
    var launchCommand: AgentHookLaunchCommandRecord?
    /// Last hook-observed `permission_mode`, re-applied on user-owned restore (#8066).
    var lastPermissionMode: String?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    /// The hook event that most recently established the persisted lifecycle.
    /// Optional so records written by older builds continue to decode.
    var hookEventName: String? = nil
    var lastSubtitle: String?
    var lastBody: String?
    var lastNotificationStatus: AgentHookNotificationStatus?
    var lastEmittedNotificationFingerprint: String?
    var lastEmittedNotificationAt: TimeInterval?
    var recentEmittedNotificationFingerprints: [String: TimeInterval]?
    var runtimeStatus: AgentHookRuntimeStatus?
    var activePromptDepth: Int?
    var activePromptTurnId: String?
    var activePromptTurnIds: [String]?
    /// Provider invocation number for the active prompt, when available.
    /// Antigravity uses this to distinguish same-turn callbacks from a new
    /// turn when it omits a turn identifier.
    var activePromptInvocationNumber: Int? = nil
    var lastPromptTurnId: String?
    /// Monotonic identity for the authoritative prompt projection. A delayed
    /// SessionEnd must only settle the exact prompt revision it observed.
    /// Optional for compatibility with state written before this fence existed.
    var promptLifecycleRevision: Int64? = nil
    var terminalPromptTurnIds: [String]?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    /// Immutable age anchor for a demoted record awaiting external cleanup.
    /// Optional for compatibility with stores written before cleanup retries
    /// became durable.
    var supersededCleanupEnqueuedAt: TimeInterval? = nil
    /// Retry ordering metadata. Attempts must not rewrite `updatedAt`, because
    /// that timestamp is also the normal session-state expiry anchor.
    var supersededCleanupLastAttemptAt: TimeInterval? = nil
    var supersededCleanupAttemptCount: Int? = nil
    // Auto-naming engine state (all optional so stores written before the
    // feature decode unchanged). The durable baseline advances only after a
    // confirmed title apply; the in-flight marker dedupes concurrent Stops.
    var autoNameLastTitle: String?
    var autoNameLastLineCount: Int?
    var autoNameLastNamedAt: TimeInterval?
    var autoNameInFlightAt: TimeInterval?
    /// Last summarization attempt, including failures, for cooldown enforcement.
    var autoNameLastAttemptAt: TimeInterval?
    var autoNameRecentMessages: [AutoNamingTranscriptMessage]?
    var autoNameMessageSequence: Int?
    var hadPendingBackgroundWorkAtStop: Bool?
    /// Unsandboxed Cursor shell calls that cmux asked Cursor to gate. The
    /// after/failure hooks do not carry a native approval decision, so the
    /// command identity is the only safe completion correlation available.
    var pendingCursorShellApprovals: [PendingCursorShellApproval]? = nil
    /// Command fingerprints cleared at a turn boundary. A recently reused
    /// command requires a stable tool id on completion because Cursor's
    /// command-only callback cannot distinguish an old delayed completion from
    /// the new turn's approval.
    var recentlyClearedCursorShellCommandFingerprints: [String: TimeInterval]? = nil
    /// Once the bounded command-only fence overflows, command-only
    /// correlation remains disabled for this session; re-enabling it after
    /// eviction would let an old delayed callback consume a newer approval.
    var cursorShellCommandOnlyCorrelationDisabled: Bool? = nil
}
