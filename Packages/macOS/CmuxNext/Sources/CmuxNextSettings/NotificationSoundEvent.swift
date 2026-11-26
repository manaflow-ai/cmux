import CmuxNextWindowRules

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

    /// The level of a notification, as the daemon sends it (`info`, `warning`, `error`).
    public enum Level: String, Sendable, Hashable {
        case info, warning, error
    }

    /// The event of a notification from `source` at `level`: errors are errors, an agent's or
    /// `cmux notify`'s warning asks for input, an agent's info is a finished turn, a terminal
    /// program's notification is a bell, the rest are messages (Rust's
    /// `notification_policy::SoundEvent::of`, op `window_notifications_sound_event`).
    public init(source: NotificationSource, level: Level) {
        struct Request: Encodable { var source: String, level: String }
        struct Reply: Decodable { var event: String }
        let reply = WindowRules().call("window_notifications_sound_event", Request(source: source.rawValue, level: level.rawValue), as: Reply.self)
        self = reply.flatMap { NotificationSoundEvent(rawValue: $0.event) } ?? .message
    }
}
