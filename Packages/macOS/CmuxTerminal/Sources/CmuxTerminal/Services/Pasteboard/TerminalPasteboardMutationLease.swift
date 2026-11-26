import os

/// Exclusive ownership after an ordered pasteboard mutation publishes.
///
/// The owner may synchronously register a dependent read before calling
/// ``finish()``, preventing another cmux-owned mutation from interleaving.
///
/// SAFETY: the unfair lock protects the complete lease state machine; no
/// mutable state is accessed outside it, and callbacks run after unlocking.
public final class TerminalPasteboardMutationLease: @unchecked Sendable {
    enum AppliedResultDisposition: Equatable {
        case ownerOwnsRestoration
        case laneMustRestore
    }

    private enum State {
        case waiting(CheckedContinuation<TerminalPasteboardMutationResult?, Never>?)
        case applied(TerminalPasteboardMutationResult)
        case finished(TerminalPasteboardMutationResult?)
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
        return await withTaskCancellationHandler {
            await suspendUntilApplied()
        } onCancel: {
            finish()
        }
    }

    /// Waits for the authoritative result without releasing on cancellation.
    ///
    /// Non-rollback mutations cannot undo a write after admission, so their
    /// caller must learn whether publication succeeded before reporting an
    /// outcome or attempting a fallback write.
    func waitForAuthoritativeResult() async -> TerminalPasteboardMutationResult? {
        await suspendUntilApplied()
    }

    private func suspendUntilApplied() async -> TerminalPasteboardMutationResult? {
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
    }

    /// Releases the lane after the owner has registered any dependent read.
    ///
    /// - Returns: The applied result when publication already finished. The
    ///   result remains available on repeated calls so a cancellation handler
    ///   cannot consume the owner's sole clipboard-restoration snapshot.
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
                state = .finished(nil)
                return (true, nil, continuation)
            case .applied(let result):
                state = .finished(result)
                return (true, result, nil)
            case .finished(let result):
                return (false, result, nil)
            }
        }
        guard outcome.shouldFinish else { return outcome.appliedResult }
        outcome.continuation?.resume(returning: nil)
        finishHandler()
        return outcome.appliedResult
    }

    /// Records the result and assigns restoration ownership by signal order.
    func signalApplied(
        _ result: TerminalPasteboardMutationResult
    ) -> AppliedResultDisposition {
        let outcome = state.withLock {
            state -> (
                continuation: CheckedContinuation<
                    TerminalPasteboardMutationResult?,
                    Never
                >?,
                disposition: AppliedResultDisposition
            ) in
            switch state {
            case .waiting(let continuation):
                state = .applied(result)
                return (continuation, .ownerOwnsRestoration)
            case .finished(nil):
                state = .finished(result)
                return (nil, .laneMustRestore)
            case .applied, .finished:
                return (nil, .ownerOwnsRestoration)
            }
        }
        outcome.continuation?.resume(returning: result)
        return outcome.disposition
    }

    deinit {
        _ = finish()
    }
}
