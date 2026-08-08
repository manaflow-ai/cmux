import os

/// Exclusive ownership after an ordered pasteboard mutation publishes.
///
/// The owner may synchronously register a dependent read before calling
/// ``finish()``, preventing another cmux-owned mutation from interleaving.
///
/// SAFETY: the unfair lock protects the complete lease state machine; no
/// mutable state is accessed outside it, and callbacks run after unlocking.
public final class TerminalPasteboardMutationLease: @unchecked Sendable {
    private enum State {
        case waiting(CheckedContinuation<TerminalPasteboardMutationResult?, Never>?)
        case applied(TerminalPasteboardMutationResult)
        case finished
    }

    let id: UInt64
    private let state = OSAllocatedUnfairLock<State>(
        initialState: .waiting(nil)
    )
    private let finishHandler: @Sendable () -> Void

    init(
        id: UInt64,
        finishHandler: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.finishHandler = finishHandler
    }

    /// Waits for this mutation to reach the head of the lane and publish.
    public func waitUntilApplied() async -> TerminalPasteboardMutationResult? {
        if Task.isCancelled {
            finish()
            return nil
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = state.withLock {
                    state -> TerminalPasteboardMutationResult?? in
                    switch state {
                    case .waiting(nil):
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        preconditionFailure("Pasteboard mutation lease awaited twice")
                    case .applied(let result):
                        return .some(result)
                    case .finished:
                        return .some(nil)
                    }
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            finish()
        }
        guard let result else { return nil }
        return state.withLock { state in
            if case .applied(let currentResult) = state {
                return currentResult
            }
            return nil
        }
    }

    /// Releases the lane after the owner has registered any dependent read.
    ///
    /// - Returns: The applied result when publication already finished. This
    ///   lets a cancelling owner restore a temporary mutation even when its
    ///   awaiting task has not resumed yet.
    @discardableResult
    public func finish() -> TerminalPasteboardMutationResult? {
        let outcome = state.withLock {
            state -> (
                shouldFinish: Bool,
                appliedResult: TerminalPasteboardMutationResult?,
                continuation: CheckedContinuation<
                    TerminalPasteboardMutationResult?,
                    Never
                >?
            ) in
            switch state {
            case .waiting(let continuation):
                state = .finished
                return (true, nil, continuation)
            case .applied(let result):
                state = .finished
                return (true, result, nil)
            case .finished:
                return (false, nil, nil)
            }
        }
        guard outcome.shouldFinish else { return nil }
        outcome.continuation?.resume(returning: nil)
        finishHandler()
        return outcome.appliedResult
    }

    func signalApplied(_ result: TerminalPasteboardMutationResult) {
        let continuation = state.withLock {
            state -> CheckedContinuation<
                TerminalPasteboardMutationResult?,
                Never
            >? in
            switch state {
            case .waiting(let continuation):
                state = .applied(result)
                return continuation
            case .applied, .finished:
                return nil
            }
        }
        continuation?.resume(returning: result)
    }

    deinit {
        _ = finish()
    }
}
