import Foundation

/// The resolution state of a single pairing gate, mirrored into an individual
/// check mark in the pairing UI (https://github.com/manaflow-ai/cmux/issues/6084).
public enum MobilePairingStageStatus: Equatable, Sendable {
    /// Not started, or left untested because an earlier gate has not cleared.
    case pending
    /// Currently being attempted.
    case inProgress
    /// Cleared.
    case succeeded
    /// Failed, carrying the localized headline and optional actionable guidance
    /// the UI shows beneath this gate's row.
    case failed(message: String, guidance: String?)

    /// Whether this gate is the one that failed.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The failure headline, when this gate failed.
    public var failureMessage: String? {
        if case let .failed(message, _) = self { return message }
        return nil
    }

    /// The actionable next-step line, when this gate failed and one applies.
    public var failureGuidance: String? {
        if case let .failed(_, guidance) = self { return guidance }
        return nil
    }
}
