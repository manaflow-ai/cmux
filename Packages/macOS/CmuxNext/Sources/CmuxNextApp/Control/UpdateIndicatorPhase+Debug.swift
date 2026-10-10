import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater

/// `debug.update_indicator {phase, version?, progress?, note?}` (DEBUG): a
/// fixed update phase for screenshots. A note shows after a check from the
/// palette; `phase: "live"` (or none) follows the updater again.
extension UpdateIndicatorPhase {
    init?(debugParams params: [String: JSONValue]) {
        switch params["phase"]?.stringValue {
        case "hidden": self = .hidden
        case "checking": self = .checking
        case "downloading": self = .downloading(progress: params["progress"]?.doubleValue)
        case "available": self = .available(version: params["version"]?.stringValue)
        case "ready": self = .ready(version: params["version"]?.stringValue)
        case "installing": self = .installing
        case "note": self = .note(UpdateNote(debugParams: params))
        default: return nil
        }
    }
}

extension UpdateNote {
    /// `{note: "up_to_date" | "check_failed" | "found" | "requires_newer_macos",
    /// version?, required?}`; `error: true` is check_failed.
    init(debugParams params: [String: JSONValue]) {
        if params["error"]?.boolValue == true {
            self = .checkFailed
            return
        }
        switch params["note"]?.stringValue {
        case "check_failed": self = .checkFailed
        case "found": self = .found(version: params["version"]?.stringValue ?? "1.99.0")
        case "requires_newer_macos":
            self = .needsNewerMacOS(version: params["version"]?.stringValue ?? "1.99.0", required: params["required"]?.stringValue ?? "27.0")
        default: self = .upToDate
        }
    }
}
