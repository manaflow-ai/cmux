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
        companion: CodexHookCompanion? = nil
    ) {
        self.agentEvent = agentEvent
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
        self.delivery = delivery
        self.companion = companion
    }
}

/// A direct handler that shares a cmux hook group with the event's main
/// handler. Its command is rendered after the main one in the same
/// `hooks=[...]` list.
public struct CodexHookCompanion: Equatable, Sendable {
    /// The cmux hook subcommand invoked for the event.
    public let cmuxSubcommand: String

    /// The timeout Codex applies to the hook command, in milliseconds.
    public let timeoutMs: Int

    public init(cmuxSubcommand: String, timeoutMs: Int) {
        self.cmuxSubcommand = cmuxSubcommand
        self.timeoutMs = timeoutMs
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
            "{type=\"command\",command='''\(try command(cmuxSubcommand))''',timeout=\(timeoutMs)}",
        ]
        if let companion {
            handlers.append(
                "{type=\"command\",command='''\(try command(companion.cmuxSubcommand))''',timeout=\(companion.timeoutMs)}"
            )
        }
        return "hooks.\(agentEvent)=[{hooks=[\(handlers.joined(separator: ","))]}]"
    }
}
