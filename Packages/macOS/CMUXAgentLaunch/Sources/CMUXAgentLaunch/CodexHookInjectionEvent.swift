/// One event entry in a cmux-generated Codex hook argument block.
public struct CodexHookInjectionEvent: Equatable, Sendable {
    /// The Codex hook event configured by this entry.
    public let agentEvent: String

    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout Codex applies to the hook command, in milliseconds.
    public let timeoutMs: Int

    /// Whether the hook may return after bounded queue admission or must keep
    /// the direct process/stdout contract for an agent decision.
    public let delivery: CodexHookDelivery

    /// Creates one schema entry. Queue delivery is the safe default for
    /// lifecycle and telemetry events; decision events opt into `.direct`.
    public init(
        agentEvent: String,
        cmuxSubcommand: String,
        timeoutMs: Int,
        delivery: CodexHookDelivery = .queued
    ) {
        self.agentEvent = agentEvent
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
        self.delivery = delivery
    }
}

/// The execution contract for a cmux-injected Codex hook.
public enum CodexHookDelivery: Equatable, Sendable {
    case queued
    case direct
}
