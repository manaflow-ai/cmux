/// What a notification is about, for its sound (`notifications.sounds.events.<event>` and each
/// level's `events`): a person usually wants "an agent needs me" to sound unlike "an agent finished".
public nonisolated enum NotificationSoundEvent: String, Hashable, Sendable, CaseIterable {
    /// An agent finished its turn.
    case finished
    /// An agent asks: a permission prompt, a question, a plan review (an agent's warning).
    case needsInput
    /// Something failed (any source's error level).
    case error
    /// A terminal program's own notification (OSC 9, 777, 99).
    case bell
    /// `cmux notify` and every other message.
    case message

    /// How loud the event is in a burst: a sound that waits behind a quieter one would be lost, so
    /// the cooldown lets a more urgent event through (``NotificationSoundThrottle``).
    public var urgency: Int {
        switch self {
        case .needsInput: 3
        case .error: 2
        case .finished, .message: 1
        case .bell: 0
        }
    }

    /// The level of a notification, as the daemon sends it (`info`, `warning`, `error`).
    public enum Level: String, Sendable, Hashable {
        case info, warning, error
    }

    /// The event of a notification from `source` at `level`: errors are errors, an agent's or
    /// `cmux notify`'s warning asks for input, an agent's info is a finished turn, a terminal
    /// program's notification is a bell, the rest are messages.
    public init(source: NotificationSource, level: Level) {
        switch (source, level) {
        case (_, .error): self = .error
        case (.agent, .warning), (.cli, .warning): self = .needsInput
        case (.agent, .info): self = .finished
        case (.terminal, _): self = .bell
        case (.cli, .info): self = .message
        }
    }
}
