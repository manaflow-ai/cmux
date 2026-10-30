import Foundation
public import CmuxNextDesignTokens

/// A state's name in a word or two (cx-sya4n): the indicator's tooltip and
/// VoiceOver label everywhere (sidebar rows, tabs, chrome), in every look.
nonisolated extension StatusIndicatorState {
    /// Nil for idle.
    public var shortLabel: String? {
        switch self {
        case .idle: nil
        case .working: String(localized: "status.label.working", defaultValue: "Working", bundle: .module)
        case .busy: String(localized: "status.label.loading", defaultValue: "Loading", bundle: .module)
        case .paused: String(localized: "status.label.paused", defaultValue: "Paused", bundle: .module)
        case .waiting(let kind):
            switch kind {
            case .permission?: String(localized: "status.label.permission", defaultValue: "Needs permission", bundle: .module)
            case .question?: String(localized: "status.label.question", defaultValue: "Question", bundle: .module)
            case .auth?: String(localized: "status.label.auth", defaultValue: "Sign-in needed", bundle: .module)
            case nil: String(localized: "status.label.waiting", defaultValue: "Waiting", bundle: .module)
            }
        case .error: String(localized: "status.label.error", defaultValue: "Error", bundle: .module)
        case .success: String(localized: "status.label.done", defaultValue: "Done", bundle: .module)
        }
    }
}
