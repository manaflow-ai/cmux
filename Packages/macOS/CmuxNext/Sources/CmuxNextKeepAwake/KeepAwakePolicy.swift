import CmuxNextSettings

/// Whether this Mac holds off idle system sleep, from who asks (the action,
/// working agents, long terminal commands, phone access) and the power source. Free of AppKit and
/// IOKit so the rule is tested on its own.
nonisolated struct KeepAwakePolicy: Equatable, Sendable {
    /// The Keep Mac Awake action is on. The person asked, so it holds on battery too.
    var manual = false
    /// An agent on this Mac runs a turn.
    var agentsWorking = false
    /// `sessions.keepAwake`.
    var agents: SessionKeepAwakeSetting = SessionSettings.keepAwakeDefault
    /// Local terminal commands that keep the Mac awake now (Rust `keep_awake_plan`).
    var commandsRunning = 0
    /// `sessions.keepAwakeForCommands`: those commands count, as `agents` allows.
    var commands = SessionSettings.keepAwakeForCommandsDefault
    /// Phones can reach this Mac (signed in, `phone.allowConnections` on).
    var phoneServing = false
    /// NEXT iPhone connections are enabled for a signed-in account. Independent of Iroh.
    var iPhoneServing = false
    /// `phone.keepAwake`.
    var phone: PhoneKeepAwakeSetting = SessionSettings.phoneKeepAwakeDefault
    /// The battery provides power (false on adapter power and on a Mac with no battery).
    var onBattery = false

    var holds: Bool {
        manual || agentsHold || phoneHolds
    }

    /// The setting behind the hold, for the menu bar line to open: agents and commands first, then
    /// phones; nil when only the Keep Mac Awake action holds, or nothing does.
    var setting: String? {
        if agentsHold { return "sessions.keepAwake" }
        if phoneHolds { return "phone.keepAwake" }
        return nil
    }

    private var agentsHold: Bool {
        (agentsWorking || (commands && commandsRunning > 0)) && Self.allows(agents, onBattery: onBattery)
    }

    private var phoneHolds: Bool {
        (phoneServing || iPhoneServing) && Self.allows(SessionKeepAwakeSetting(rawValue: phone.rawValue) ?? .off, onBattery: onBattery)
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
