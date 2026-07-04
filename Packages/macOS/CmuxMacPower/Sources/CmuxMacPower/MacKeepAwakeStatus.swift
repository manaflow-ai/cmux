/// A structured snapshot of whether the Mac is being kept awake, and by whom.
///
/// The booleans are derived from the per-process assertion holders so the phone
/// can render a localized summary ("Kept awake by caffeinate") without parsing
/// pmset text itself. The wire form (``jsonObject``) is the single source of
/// truth for the keys the iOS `MobileMacPowerStatus` decoder mirrors.
public struct MacKeepAwakeStatus: Sendable, Equatable, Codable {
    /// True when anything is preventing the Mac or its display from idle-sleeping.
    public let keptAwake: Bool
    /// True when a process holds a system idle/forced sleep-prevention assertion.
    public let preventsSystemSleep: Bool
    /// True when a process holds a display idle sleep-prevention assertion.
    public let preventsDisplaySleep: Bool
    /// True when cmux itself holds a keep-awake assertion.
    public let cmuxKeepingAwake: Bool
    /// True when a `caffeinate` process holds a keep-awake assertion.
    public let caffeinateRunning: Bool
    /// Every process currently holding a keep-awake assertion.
    public let holders: [MacPowerAssertionHolder]

    /// Creates a structured keep-awake snapshot from parsed assertion holders.
    public init(
        keptAwake: Bool,
        preventsSystemSleep: Bool,
        preventsDisplaySleep: Bool,
        cmuxKeepingAwake: Bool,
        caffeinateRunning: Bool,
        holders: [MacPowerAssertionHolder]
    ) {
        self.keptAwake = keptAwake
        self.preventsSystemSleep = preventsSystemSleep
        self.preventsDisplaySleep = preventsDisplaySleep
        self.cmuxKeepingAwake = cmuxKeepingAwake
        self.caffeinateRunning = caffeinateRunning
        self.holders = holders
    }

    /// Nothing is keeping the Mac awake.
    public static let idle = MacKeepAwakeStatus(
        keptAwake: false,
        preventsSystemSleep: false,
        preventsDisplaySleep: false,
        cmuxKeepingAwake: false,
        caffeinateRunning: false,
        holders: []
    )

    /// JSON-serializable wire form for the mobile RPC (`mac.power.status`). The
    /// snake-cased keys are mirrored by the iOS `MobileMacPowerStatus` decoder.
    public var jsonObject: [String: Any] {
        [
            "kept_awake": keptAwake,
            "prevents_system_sleep": preventsSystemSleep,
            "prevents_display_sleep": preventsDisplaySleep,
            "cmux_keeping_awake": cmuxKeepingAwake,
            "caffeinate_running": caffeinateRunning,
            "holders": holders.map { holder -> [String: Any] in
                var object: [String: Any] = [
                    "pid": holder.pid,
                    "process": holder.processName,
                    "types": holder.assertionTypes,
                ]
                if let detail = holder.detail {
                    object["detail"] = detail
                }
                return object
            },
        ]
    }
}
