import CmuxFoundation
import Foundation

/// A refused receipt-based config mutation. Nothing was published.
public enum JSONConfigMutationError: LocalizedError, Sendable {
    /// Undo no longer owns this path: a newer value is installed, or the
    /// configured symlink now resolves to a different file. The JSON values
    /// stay local to the caller for a preview; they are not in the message.
    case undoConflict(path: String, expected: Data?, current: Data?, restore: Data?)
    /// The canonical global schema rejected the complete candidate.
    case invalidCandidate([CmuxConfigSemanticIssue])

    /// Localized recovery guidance that never includes config values.
    public var errorDescription: String? {
        switch self {
        case .undoConflict(let path, _, _, _):
            let message = String(
                localized: "settings.configMutation.undoConflict",
                defaultValue: "Undo preserved a newer choice. Review this setting before changing it:"
            )
            return "\(message) \(path)"
        case .invalidCandidate(let issues):
            let message = String(
                localized: "settings.configMutation.invalidCandidate",
                defaultValue: "The proposed config is invalid. No changes were saved."
            )
            return ([message] + issues.map { "\($0.path): \($0.message)" }).joined(separator: "\n")
        }
    }
}
