import Foundation
public import CmuxNextDesignTokens

/// A state's name in a word or two (cx-sya4n): the indicator's tooltip and
/// VoiceOver label everywhere (sidebar rows, tabs, chrome), in every look.
nonisolated extension StatusIndicatorState {
    /// Nil for idle.
    public var shortLabel: String? {
        switch self {
        case .idle: nil
        case .working: String(localized: "status.label.working", defaultValue: "Working", bundle: .localizedModule)
        case .busy: String(localized: "status.label.loading", defaultValue: "Loading", bundle: .localizedModule)
        case .paused: String(localized: "status.label.paused", defaultValue: "Paused", bundle: .localizedModule)
        case .waiting(let kind):
            switch kind {
            case .permission?: String(localized: "status.label.permission", defaultValue: "Needs permission", bundle: .localizedModule)
            case .question?: String(localized: "status.label.question", defaultValue: "Question", bundle: .localizedModule)
            case .auth?: String(localized: "status.label.auth", defaultValue: "Sign-in needed", bundle: .localizedModule)
            case nil: String(localized: "status.label.waiting", defaultValue: "Waiting", bundle: .localizedModule)
            }
        case .error: String(localized: "status.label.error", defaultValue: "Error", bundle: .localizedModule)
        case .success: String(localized: "status.label.done", defaultValue: "Done", bundle: .localizedModule)
        }
    }
}
