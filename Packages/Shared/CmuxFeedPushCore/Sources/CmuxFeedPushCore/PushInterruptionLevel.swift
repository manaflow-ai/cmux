/// `aps.interruption-level` (and `UNNotificationInterruptionLevel`).
public enum PushInterruptionLevel: String, Hashable, Sendable {
    case passive
    case active
    case timeSensitive = "time-sensitive"
    case critical
}
