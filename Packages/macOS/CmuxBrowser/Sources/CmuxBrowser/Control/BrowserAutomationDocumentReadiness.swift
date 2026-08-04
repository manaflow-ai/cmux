public import Foundation

/// Tracks the first committed document for the browser instance owned by one panel.
///
/// The owner calls ``bind(to:hasCommittedDocument:)`` whenever it replaces its WebView and
/// ``didCommit(instanceID:)`` from the corresponding navigation-delegate callback. Automation
/// callers can then await the real lifecycle signal without polling WebKit state.
@MainActor
public final class BrowserAutomationDocumentReadiness {
    private var observedInstanceID: UUID?
    private var committedInstanceID: UUID?
    private var waiters: [UUID: AsyncStream<BrowserAutomationDocumentReadinessOutcome>.Continuation] = [:]

    /// Creates an empty document-readiness owner.
    public init() {}

    /// Starts observing a browser instance and supersedes waits for any previous instance.
    /// - Parameters:
    ///   - instanceID: Stable identity of the newly bound browser instance.
    ///   - hasCommittedDocument: Whether the instance committed before the owner attached its delegate.
    public func bind(to instanceID: UUID, hasCommittedDocument: Bool) {
        if observedInstanceID == instanceID {
            if hasCommittedDocument, committedInstanceID != instanceID {
                committedInstanceID = instanceID
                finishWaiters(with: .committed)
            }
            return
        }

        finishWaiters(with: .superseded)
        observedInstanceID = instanceID
        committedInstanceID = hasCommittedDocument ? instanceID : nil
    }

    /// Records a navigation commit when it belongs to the currently bound browser instance.
    /// - Parameter instanceID: Identity captured when the navigation delegate was bound.
    public func didCommit(instanceID: UUID) {
        guard observedInstanceID == instanceID else { return }
        committedInstanceID = instanceID
        finishWaiters(with: .committed)
    }

    /// Stops observing the current browser instance and cancels its pending waits.
    public func invalidate() {
        observedInstanceID = nil
        committedInstanceID = nil
        finishWaiters(with: .cancelled)
    }

    /// Returns whether the currently bound browser instance has committed a document.
    /// - Parameter instanceID: Browser instance to inspect.
    /// - Returns: `true` only after that exact instance produced a commit signal.
    public func hasCommittedDocument(for instanceID: UUID) -> Bool {
        observedInstanceID == instanceID && committedInstanceID == instanceID
    }

    /// Waits for a real commit signal from the specified browser instance.
    /// - Parameter instanceID: Browser instance whose first document is required.
    /// - Returns: Whether the instance committed, was superseded, or the wait was cancelled.
    public func waitForCommit(
        instanceID: UUID
    ) async -> BrowserAutomationDocumentReadinessOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard observedInstanceID == instanceID else { return .superseded }
        guard committedInstanceID != instanceID else { return .committed }

        let waiterID = UUID()
        let (events, continuation) = AsyncStream.makeStream(
            of: BrowserAutomationDocumentReadinessOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        waiters[waiterID] = continuation
        defer {
            waiters.removeValue(forKey: waiterID)
            continuation.finish()
        }
        var iterator = events.makeAsyncIterator()
        return await iterator.next() ?? .cancelled
    }

    private func finishWaiters(with outcome: BrowserAutomationDocumentReadinessOutcome) {
        let pendingWaiters = Array(waiters.values)
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.yield(outcome)
            waiter.finish()
        }
    }
}
