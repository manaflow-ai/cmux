import CmuxFoundation
import Foundation

/// A refused config mutation; disk publication did not occur.
public enum JSONConfigMutationError: LocalizedError, Sendable {
    /// Another participating writer owns the target; retry from fresh state.
    case busy
    /// The configured target or source changed while preparing the write.
    case sourceChanged
    /// Undo no longer owns this path. Values stay local to the caller for preview.
    case undoConflict(path: String, expected: Data?, current: Data?, restore: Data?)
    /// The canonical schema rejected the complete candidate.
    case invalidCandidate([CmuxConfigSemanticIssue])

    /// Localized recovery guidance without exposing private config values.
    public var errorDescription: String? {
        switch self {
        case .busy:
            return String(localized: "settings.configMutation.busy", defaultValue: "Another config edit is in progress. Retry your change.")
        case .sourceChanged:
            return String(localized: "settings.configMutation.sourceChanged", defaultValue: "The config changed while this edit was prepared. Review it and retry.")
        case .undoConflict(let path, _, _, _):
            let message = String(localized: "settings.configMutation.undoConflict", defaultValue: "Undo preserved a newer choice. Review this setting before changing it:")
            return "\(message) \(path)"
        case .invalidCandidate(let issues):
            let message = String(localized: "settings.configMutation.invalidCandidate", defaultValue: "The proposed config is invalid. No changes were saved.")
            return ([message] + issues.map { "\($0.path): \($0.message)" }).joined(separator: "\n")
        }
    }
}
