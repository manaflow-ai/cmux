/// One process currently holding a power assertion that keeps the Mac (or its
/// display) awake, as reported by `pmset -g assertions`.
public struct MacPowerAssertionHolder: Sendable, Equatable, Codable {
    /// The owning process id.
    public let pid: Int
    /// The owning process name (e.g. `caffeinate`, `cmux`, `Google Chrome`).
    public let processName: String
    /// The assertion types this process holds, e.g. `PreventUserIdleSystemSleep`.
    public let assertionTypes: [String]
    /// The human-readable assertion reason (pmset's `named:` field), if present.
    public let detail: String?

    public init(pid: Int, processName: String, assertionTypes: [String], detail: String?) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
        self.detail = detail
    }
}

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

/// The result of ``MacPowerController/disableKeepAwake()``.
public struct MacKeepAwakeDisableOutcome: Sendable, Equatable {
    /// True if at least one `caffeinate` process was signaled (pkill exit 0).
    public let terminatedCaffeinate: Bool
    /// The keep-awake status re-read after the disable ran.
    public let status: MacKeepAwakeStatus

    public init(terminatedCaffeinate: Bool, status: MacKeepAwakeStatus) {
        self.terminatedCaffeinate = terminatedCaffeinate
        self.status = status
    }
}
