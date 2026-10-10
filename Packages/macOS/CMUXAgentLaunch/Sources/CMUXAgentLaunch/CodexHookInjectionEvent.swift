/// One event entry in a cmux-generated Codex hook argument block.
public struct CodexHookInjectionEvent: Equatable, Sendable {
    /// The Codex hook event configured by this entry.
    public let agentEvent: String

    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout source value used by cmux's hook delivery policy, in milliseconds.
    public let timeoutMs: Int

    /// The literal timeout value rendered into Codex configuration.
    ///
    /// Current schemas store seconds here, rounded up from ``timeoutMs``.
    /// Compatibility schemas may retain the historical millisecond value so
    /// replay sanitization can remove saved commands from older cmux builds.
    public let codexTimeoutValue: Int

    /// Whether the hook may return after bounded queue admission or must keep
    /// the direct process/stdout contract for an agent decision.
    public let delivery: CodexHookDelivery

    /// A second handler in the same hook group, always run directly so its
    /// stdout reaches Codex. Used to hand agent messages to Codex without
    /// making the lifecycle handler synchronous.
    public let companion: CodexHookCompanion?

    /// Creates one schema entry. Queue delivery is the safe default for
    /// lifecycle and telemetry events; decision events opt into `.direct`.
    public init(
        agentEvent: String,
        cmuxSubcommand: String,
        timeoutMs: Int,
        delivery: CodexHookDelivery = .queued,
        companion: CodexHookCompanion? = nil,
        codexTimeoutValue: Int? = nil
    ) {
        self.agentEvent = agentEvent
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
        self.codexTimeoutValue = codexTimeoutValue ?? Self.codexTimeoutSeconds(fromMilliseconds: timeoutMs)
        self.delivery = delivery
        self.companion = companion
    }

    /// Returns a copy that renders the supplied literal timeout value.
    /// - Parameter value: The timeout literal to preserve in generated argv.
    func withCodexTimeoutValue(_ value: Int) -> Self {
        Self(
            agentEvent: agentEvent,
            cmuxSubcommand: cmuxSubcommand,
            timeoutMs: timeoutMs,
            delivery: delivery,
            companion: companion?.withCodexTimeoutValue(companion?.timeoutMs ?? value),
            codexTimeoutValue: value
        )
    }

    /// Converts a positive millisecond policy value to a ceiling-rounded second value.
    private static func codexTimeoutSeconds(fromMilliseconds milliseconds: Int) -> Int {
        ((max(milliseconds, 1) - 1) / 1_000) + 1
    }
}

/// A direct handler that shares a cmux hook group with the event's main
/// handler. Its command is rendered after the main one in the same
/// `hooks=[...]` list.
public struct CodexHookCompanion: Equatable, Sendable {
    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout source value used by cmux's hook delivery policy, in milliseconds.
    public let timeoutMs: Int

    /// The literal timeout value rendered into Codex configuration.
    public let codexTimeoutValue: Int

    /// Creates a companion handler timeout entry.
    /// - Parameters:
    ///   - cmuxSubcommand: The cmux hook subcommand invoked by the handler.
    ///   - timeoutMs: The source timeout policy in milliseconds.
    ///   - codexTimeoutValue: An optional literal override used by replay compatibility schemas.
    public init(cmuxSubcommand: String, timeoutMs: Int, codexTimeoutValue: Int? = nil) {
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
        self.codexTimeoutValue = codexTimeoutValue ?? ((max(timeoutMs, 1) - 1) / 1_000) + 1
    }

    /// Returns a copy that renders the supplied literal timeout value.
    func withCodexTimeoutValue(_ value: Int) -> Self {
        Self(cmuxSubcommand: cmuxSubcommand, timeoutMs: timeoutMs, codexTimeoutValue: value)
    }
}

/// The execution contract for a cmux-injected Codex hook.
public enum CodexHookDelivery: Equatable, Sendable {
    case queued
    case direct
}

extension CodexHookInjectionEvent {
    /// The `-c` value cmux passes to Codex for this event:
    /// `hooks.<event>=[{hooks=[...]}]` with the main handler, then the
    /// companion if there is one. `command` maps a cmux subcommand to the
    /// shell command that runs it. Generation and the tests share this so the
    /// sanitizer's expected shape has one source.
    public func configValue(command: (String) throws -> String) rethrows -> String {
        var handlers = [
            "{type=\"command\",command='''\(try command(cmuxSubcommand))''',timeout=\(codexTimeoutValue)}",
        ]
        if let companion {
            handlers.append(
                "{type=\"command\",command='''\(try command(companion.cmuxSubcommand))''',timeout=\(companion.codexTimeoutValue)}"
            )
        }
        return "hooks.\(agentEvent)=[{hooks=[\(handlers.joined(separator: ","))]}]"
    }
}
