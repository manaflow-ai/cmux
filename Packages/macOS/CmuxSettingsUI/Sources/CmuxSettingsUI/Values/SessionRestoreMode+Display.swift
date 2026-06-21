import CmuxSettings
import Foundation

/// UI-facing labels for ``SessionRestoreMode`` shown in the Sessions
/// settings picker.
extension SessionRestoreMode {
    /// Canonical UI ordering of the three modes.
    static var uiCases: [SessionRestoreMode] {
        [.always, .ask, .never]
    }

    /// Short label shown in the restore-mode picker.
    var displayName: String {
        switch self {
        case .always:
            return String(localized: "settings.session.restoreMode.always", defaultValue: "Always restore")
        case .ask:
            return String(localized: "settings.session.restoreMode.ask", defaultValue: "Ask each time")
        case .never:
            return String(localized: "settings.session.restoreMode.never", defaultValue: "Never restore")
        }
    }

    /// One-sentence row subtitle explaining the behavior.
    var modeDescription: String {
        switch self {
        case .always:
            return String(localized: "settings.session.restoreMode.always.description", defaultValue: "Reopen your previous windows, tabs, and panes automatically on launch.")
        case .ask:
            return String(localized: "settings.session.restoreMode.ask.description", defaultValue: "Ask whether to restore the previous session each time cmux launches.")
        case .never:
            return String(localized: "settings.session.restoreMode.never.description", defaultValue: "Start fresh on launch. The previous session stays reopenable from File ▸ Restore Previous Launch.")
        }
    }
}
