/// One event entry in a cmux-generated Codex hook argument block.
public struct CodexHookInjectionEvent: Equatable, Sendable {
    /// The Codex hook event configured by this entry.
    public let agentEvent: String

    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout Codex applies to the hook command, in milliseconds.
    public let timeoutMs: Int

    /// Whether the hook must finish its cmux-owned lifecycle write before
    /// Codex advances to the next event. Completion/status hooks remain
    /// fire-and-forget; child lifecycle events use the synchronous boundary.
    public let isSynchronous: Bool

    /// Creates one generated Codex hook event.
    public init(
        agentEvent: String,
        cmuxSubcommand: String,
        timeoutMs: Int,
        isSynchronous: Bool = false
    ) {
        self.agentEvent = agentEvent
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
        self.isSynchronous = isSynchronous
    }
}
