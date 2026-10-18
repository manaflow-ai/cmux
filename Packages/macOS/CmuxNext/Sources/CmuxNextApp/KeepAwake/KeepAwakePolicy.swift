import CmuxNextSettings

/// Whether this Mac holds off idle system sleep, from who asks and the power
/// source. Free of AppKit and IOKit so the rule is tested on its own.
nonisolated struct KeepAwakePolicy: Equatable, Sendable {
    /// The Keep Mac Awake action is on. The person asked, so it holds on battery too.
    var manual = false
    /// An agent on this Mac runs a turn.
    var agentsWorking = false
    /// `sessions.keepAwake`.
    var agents: SessionKeepAwakeSetting = SessionSettings.keepAwakeDefault
    /// The battery provides power (false on adapter power and on a Mac with no battery).
    var onBattery = false

    var holds: Bool {
        manual || (agentsWorking && Self.allows(agents, onBattery: onBattery))
    }

    /// Whether a keep-awake choice applies on the current power source.
    static func allows(_ choice: SessionKeepAwakeSetting, onBattery: Bool) -> Bool {
        switch choice {
        case .off: false
        case .pluggedIn: !onBattery
        case .always: true
        }
    }
}
