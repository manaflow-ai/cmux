/// An ordered Codex hook block that cmux can generate or safely remove from
/// captured launch arguments.
public struct CodexHookInjectionSchema: Equatable, Sendable {
    /// The hook events in their required argument order.
    public let events: [CodexHookInjectionEvent]

    private init(events: [CodexHookInjectionEvent]) {
        self.events = events
    }

    /// The schema emitted by current cmux wrappers.
    ///
    /// Keep generation and replay
    /// sanitization on this shared value so a format change cannot update only
    /// one side of the boundary.
    public static let current = Self(events: [
        .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start", timeoutMs: 10000),
        .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit", timeoutMs: 10000),
        .init(agentEvent: "Stop", cmuxSubcommand: "stop", timeoutMs: 10000),
        .init(agentEvent: "PreToolUse", cmuxSubcommand: "pre-tool-use", timeoutMs: 120000),
        .init(agentEvent: "PostToolUse", cmuxSubcommand: "post-tool-use", timeoutMs: 10000),
        .init(agentEvent: "PermissionRequest", cmuxSubcommand: "notification", timeoutMs: 120000),
        .init(agentEvent: "SubagentStart", cmuxSubcommand: "subagent-start", timeoutMs: 10000, isSynchronous: true),
        .init(agentEvent: "SubagentStop", cmuxSubcommand: "subagent-stop", timeoutMs: 10000, isSynchronous: true),
    ])

    /// Exact older shapes accepted by saved-layout and replay sanitization.
    /// These remain explicit because stored commands can outlive the cmux
    /// version that captured them. Never broaden this to unordered events or
    /// arbitrary prefixes: hook config is user-controlled argv.
    static let recognized = [
        current,
        // The immediately previous wrapper generation had the same six
        // events but no native child callbacks. Keep it removable from saved
        // launch argv so an upgrade cannot leave two Stop producers active.
        Self(events: [
            .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start", timeoutMs: 10000),
            .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit", timeoutMs: 10000),
            .init(agentEvent: "Stop", cmuxSubcommand: "stop", timeoutMs: 10000),
            .init(agentEvent: "PreToolUse", cmuxSubcommand: "pre-tool-use", timeoutMs: 120000),
            .init(agentEvent: "PostToolUse", cmuxSubcommand: "post-tool-use", timeoutMs: 10000),
            .init(agentEvent: "PermissionRequest", cmuxSubcommand: "notification", timeoutMs: 120000),
        ]),
        Self(events: [
            .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start", timeoutMs: 10000),
            .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit", timeoutMs: 10000),
            .init(agentEvent: "PreToolUse", cmuxSubcommand: "pre-tool-use", timeoutMs: 10000),
            .init(agentEvent: "PostToolUse", cmuxSubcommand: "post-tool-use", timeoutMs: 10000),
            .init(agentEvent: "Notification", cmuxSubcommand: "notification", timeoutMs: 10000),
            .init(agentEvent: "Stop", cmuxSubcommand: "stop", timeoutMs: 10000),
        ]),
        Self(events: [
            .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start", timeoutMs: 10000),
            .init(agentEvent: "SessionStop", cmuxSubcommand: "stop", timeoutMs: 10000),
            .init(agentEvent: "Notification", cmuxSubcommand: "notification", timeoutMs: 10000),
        ]),
    ]
}
