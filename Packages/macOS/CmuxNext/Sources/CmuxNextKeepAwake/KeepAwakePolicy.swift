import CmuxNextSettings

/// Whether this Mac holds off idle system sleep, from who asks (the action,
/// working agents, phone access) and the power source. Free of AppKit and
/// IOKit so the rule is tested on its own.
nonisolated struct KeepAwakePolicy: Equatable, Sendable {
    /// The Keep Mac Awake action is on. The person asked, so it holds on battery too.
    var manual = false
    /// An agent on this Mac runs a turn.
    var agentsWorking = false
    /// `sessions.keepAwake`.
    var agents: SessionKeepAwakeSetting = SessionSettings.keepAwakeDefault
    /// Phones can reach this Mac (signed in, `phone.allowConnections` on).
    var phoneServing = false
    /// NEXT iPhone connections are enabled for a signed-in account. Independent of Iroh.
    var iPhoneServing = false
    /// `phone.keepAwake`.
    var phone: PhoneKeepAwakeSetting = SessionSettings.phoneKeepAwakeDefault
    /// The battery provides power (false on adapter power and on a Mac with no battery).
    var onBattery = false

    var holds: Bool {
        manual || (agentsWorking && Self.allows(agents, onBattery: onBattery))
            || ((phoneServing || iPhoneServing) && Self.allows(SessionKeepAwakeSetting(rawValue: phone.rawValue) ?? .off, onBattery: onBattery))
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
