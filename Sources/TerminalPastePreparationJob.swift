import Foundation

/// Actor-isolated lifecycle state for one paste-preparation request.
struct TerminalPastePreparationJob {
    enum Phase {
        case preparing
        case cancelling(TerminalPastePreparationFailure)
    }

    let id: UUID
    let request: TerminalPastePreparationRequest
    let continuation: CheckedContinuation<
        Result<
            TerminalPastePreparationResult,
            TerminalPastePreparationFailure
        >,
        Never
    >
    var phase: Phase = .preparing
    var deadlineTask: Task<Void, Never>?
    /// Identifies `deadlineTask`; an expiry from a replaced task is ignored.
    var deadlineGeneration = UUID()
    var operationTask: Task<Void, Never>?
}
