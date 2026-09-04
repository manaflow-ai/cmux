import Foundation

/// Converts stable ownership reason codes into localized human-facing labels.
///
/// Reason codes remain raw in structured payloads so clients can make stable
/// decisions; only presentation layers call this mapper.
enum CmuxTopMemoryReasonLocalization {
    /// Returns a localized label, falling back to the raw code for new reasons.
    static func label(for rawReason: String) -> String {
        let key: StaticString
        let fallback: String.LocalizationValue
        switch rawReason {
        case "cmux-explicit-scope", "cmux-process-scope", "cmux-environment", "cmux-hook-arguments":
            key = "taskManager.memory.reason.cmuxScope"
            fallback = "cmux scope"
        case "cmux-descendant", "child-process":
            key = "taskManager.memory.reason.descendant"
            fallback = "cmux descendant"
        case "cmux-process-group":
            key = "taskManager.memory.reason.processGroup"
            fallback = "cmux process group"
        case "same-tty-unproven":
            key = "taskManager.memory.reason.sameTTYUnproven"
            fallback = "same TTY (ownership unproven)"
        case "conflicting-cmux-scope":
            key = "taskManager.memory.reason.conflictingScope"
            fallback = "conflicting cmux scope"
        case "webview-root-pid":
            key = "taskManager.memory.reason.webViewRoot"
            fallback = "WebKit root process"
        case "surface-process-tree", "status-tag-process-tree", "explicit-root-pid", "included-process":
            key = "taskManager.memory.reason.processTree"
            fallback = "process tree"
        case "shared-surface-process-tree", "shared-pane-process-tree", "shared-workspace-process-tree":
            key = "taskManager.memory.reason.sharedProcessTree"
            fallback = "shared process tree"
        case "multiple-evidence":
            key = "taskManager.memory.reason.multipleEvidence"
            fallback = "multiple evidence sources"
        case "unattributed":
            return String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed")
        default:
            return rawReason
        }
        return String(localized: key, defaultValue: fallback)
    }
}
