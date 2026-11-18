import Foundation
public import CmuxNextDesignTokens

/// A state's name in a word or two (cx-sya4n): the indicator's tooltip and
/// VoiceOver label everywhere (sidebar rows, tabs, chrome), in every look.
nonisolated extension StatusIndicatorState {
    /// Nil for idle.
    public var shortLabel: String? {
        switch self {
        case .idle: nil
        case .working: String(localized: "status.label.working", defaultValue: "Working", bundle: .l10n)
        case .busy: String(localized: "status.label.loading", defaultValue: "Loading", bundle: .l10n)
        case .paused: String(localized: "status.label.paused", defaultValue: "Paused", bundle: .l10n)
        case .waiting(let kind):
            switch kind {
            case .permission?: String(localized: "status.label.permission", defaultValue: "Needs permission", bundle: .l10n)
            case .question?: String(localized: "status.label.question", defaultValue: "Question", bundle: .l10n)
            case .auth?: String(localized: "status.label.auth", defaultValue: "Sign-in needed", bundle: .l10n)
            case nil: String(localized: "status.label.waiting", defaultValue: "Waiting", bundle: .l10n)
            }
        case .error: String(localized: "status.label.error", defaultValue: "Error", bundle: .l10n)
        case .success: String(localized: "status.label.done", defaultValue: "Done", bundle: .l10n)
        }
    }
}
