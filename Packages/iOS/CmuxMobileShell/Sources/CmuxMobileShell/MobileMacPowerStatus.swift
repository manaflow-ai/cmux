/// Whether the connected Mac is currently being kept awake, and by whom.
///
/// Mirrors the Mac's `mac.power.status` result
/// (`CmuxMacPower.MacKeepAwakeStatus`). The booleans drive a localized summary
/// on the phone; `holders` backs the per-process detail rows.
public struct MobileMacPowerStatus: Decodable, Sendable, Equatable {
    /// True when anything is preventing the Mac or its display from idle-sleeping.
    public let keptAwake: Bool

    /// True when a process holds a system idle or forced sleep-prevention assertion.
    public let preventsSystemSleep: Bool

    /// True when a process holds a display idle sleep-prevention assertion.
    public let preventsDisplaySleep: Bool

    /// True when cmux itself holds a keep-awake assertion.
    public let cmuxKeepingAwake: Bool

    /// True when a `caffeinate` process holds a keep-awake assertion.
    public let caffeinateRunning: Bool

    /// The processes currently holding keep-awake assertions.
    public let holders: [MobileMacPowerHolder]

    private enum CodingKeys: String, CodingKey {
        case keptAwake = "kept_awake"
        case preventsSystemSleep = "prevents_system_sleep"
        case preventsDisplaySleep = "prevents_display_sleep"
        case cmuxKeepingAwake = "cmux_keeping_awake"
        case caffeinateRunning = "caffeinate_running"
        case holders
    }

    /// Decodes a status snapshot from the Mac power-control wire payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keptAwake = (try container.decodeIfPresent(Bool.self, forKey: .keptAwake)) ?? false
        preventsSystemSleep = (try container.decodeIfPresent(Bool.self, forKey: .preventsSystemSleep)) ?? false
        preventsDisplaySleep = (try container.decodeIfPresent(Bool.self, forKey: .preventsDisplaySleep)) ?? false
        cmuxKeepingAwake = (try container.decodeIfPresent(Bool.self, forKey: .cmuxKeepingAwake)) ?? false
        caffeinateRunning = (try container.decodeIfPresent(Bool.self, forKey: .caffeinateRunning)) ?? false
        holders = (try container.decodeIfPresent([MobileMacPowerHolder].self, forKey: .holders)) ?? []
    }

    /// Creates a status snapshot for tests and local UI state.
    public init(
        keptAwake: Bool,
        preventsSystemSleep: Bool,
        preventsDisplaySleep: Bool,
        cmuxKeepingAwake: Bool,
        caffeinateRunning: Bool,
        holders: [MobileMacPowerHolder]
    ) {
        self.keptAwake = keptAwake
        self.preventsSystemSleep = preventsSystemSleep
        self.preventsDisplaySleep = preventsDisplaySleep
        self.cmuxKeepingAwake = cmuxKeepingAwake
        self.caffeinateRunning = caffeinateRunning
        self.holders = holders
    }
}
