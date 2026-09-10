import Foundation

/// Actor-isolated lifecycle state for one paste-preparation request.
struct TerminalPastePreparationJob {
    let id: UUID
    let request: TerminalPastePreparationRequest
    var continuation: CheckedContinuation<
        Result<
            TerminalPastePreparationResult,
            TerminalPastePreparationFailure
        >,
        Never
    >?
    var deadlineTask: Task<Void, Never>?
    var operationTask: Task<Void, Never>?
}
