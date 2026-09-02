public import Foundation
internal import os

/// Delivers the eventual result of one queued compound prompt submission.
///
/// A caller can acknowledge admission immediately while retaining a receipt
/// that completes only when the queued paste-and-submit transaction is sent or
/// fails definitively. The stream is bounded to one result because a receipt
/// represents exactly one terminal transaction.
public final class PromptSubmissionDeliveryReceipt: Sendable {
    private enum State {
        case pending
        case delivering
        case finished(PromptSubmissionSendResult)
        case cancelled
    }

    private let results: AsyncStream<PromptSubmissionSendResult>
    private let continuation: AsyncStream<PromptSubmissionSendResult>.Continuation
    // A short compare-and-set protects one-shot publication when a timeout or
    // surface teardown races the MainActor delivery callback.
    private let state = OSAllocatedUnfairLock<State>(initialState: .pending)

    /// Creates an unresolved delivery receipt.
    public init() {
        let stream = AsyncStream<PromptSubmissionSendResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        results = stream.stream
        continuation = stream.continuation
    }

    /// Claims the one terminal-write transition for this receipt.
    ///
    /// Timeout cancellation can race the MainActor callback between its last
    /// validation and the first byte write. Claiming `delivering` closes that
    /// gap: a timeout either cancels before any write or waits for this claim
    /// to finish.
    ///
    /// - Returns: `true` when this receipt transitioned into delivery.
    @discardableResult
    public func beginDelivery() -> Bool {
        state.withLock { state in
            guard case .pending = state else { return false }
            state = .delivering
            return true
        }
    }

    /// Completes the receipt with the terminal delivery outcome.
    ///
    /// The owning surface calls this exactly once when the compound
    /// transaction is sent or rejected after admission.
    public func finish(_ result: PromptSubmissionSendResult) {
        let shouldPublish = state.withLock { state in
            switch state {
            case .pending, .delivering:
                state = .finished(result)
                return true
            case .finished, .cancelled:
                return false
            }
        }
        guard shouldPublish else { return }
        continuation.yield(result)
        continuation.finish()
    }

    /// Cancels delivery and publishes a definitive unavailable outcome.
    ///
    /// - Returns: `true` when this call won the pending-to-cancel transition.
    @discardableResult
    public func cancel() -> Bool {
        let shouldPublish = state.withLock { state in
            guard case .pending = state else { return false }
            state = .cancelled
            return true
        }
        guard shouldPublish else { return false }
        continuation.yield(.surfaceUnavailable)
        continuation.finish()
        return true
    }

    /// Cancels a pending delivery or waits for an already-started write.
    ///
    /// - Returns: The definitive delivery result, or `.surfaceUnavailable`
    ///   when cancellation won before delivery began.
    public func cancelAndWait() async -> PromptSubmissionSendResult {
        enum Action {
            case cancelled(shouldPublish: Bool)
            case wait
            case result(PromptSubmissionSendResult)
        }
        let action = state.withLock { state -> Action in
            switch state {
            case .pending:
                state = .cancelled
                return .cancelled(shouldPublish: true)
            case .delivering:
                return .wait
            case .finished(let result):
                return .result(result)
            case .cancelled:
                return .cancelled(shouldPublish: false)
            }
        }
        switch action {
        case .cancelled(let shouldPublish):
            if shouldPublish {
                continuation.yield(.surfaceUnavailable)
                continuation.finish()
            }
            return .surfaceUnavailable
        case .wait:
            // A cancelled caller must still wait after the write claim. An
            // unstructured shield keeps the receipt waiter alive while the
            // MainActor completes the already-started terminal transaction.
            return await Task.detached(priority: .userInitiated) { [self] in
                await self.wait()
            }.value
        case .result(let result):
            return result
        }
    }

    /// Whether a timeout or teardown has already cancelled this transaction.
    public var isCancelled: Bool {
        state.withLock { state in
            if case .cancelled = state { true } else { false }
        }
    }

    /// Waits for the terminal delivery outcome.
    ///
    /// A stream that ends without a result is treated as an unavailable
    /// surface so a transaction lane never remains occupied by a broken
    /// receipt.
    public func wait() async -> PromptSubmissionSendResult {
        if Task.isCancelled {
            _ = cancel()
            return .surfaceUnavailable
        }
        let terminalResult = state.withLock { state -> PromptSubmissionSendResult? in
            switch state {
            case .finished(let result):
                return result
            case .cancelled:
                return .surfaceUnavailable
            case .pending, .delivering:
                return nil
            }
        }
        if let terminalResult {
            return terminalResult
        }
        return await withTaskCancellationHandler {
            for await result in results {
                return result
            }
            return state.withLock { state in
                if case .finished(let result) = state { return result }
                return .surfaceUnavailable
            }
        } onCancel: {
            _ = cancel()
        }
    }
}
