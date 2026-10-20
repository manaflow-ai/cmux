public import Foundation

/// Tracks the first committed document for the browser instance owned by one panel.
///
/// The owner calls ``bind(to:hasCommittedDocument:)`` whenever it replaces its WebView and
/// ``didCommit(instanceID:)`` from the corresponding navigation-delegate callback. Automation
/// callers can then await the real lifecycle signal without polling WebKit state.
@MainActor
public final class BrowserAutomationDocumentReadiness {
    /// Identifies the lifecycle callback that made a browser document available to automation.
    public enum Signal: String, Sendable {
        /// WebKit delivered the main-frame navigation delegate commit callback.
        case nativeCommit = "native_commit"

        /// The isolated cmux document-end bridge delivered a ready-state callback.
        case documentReadyBridge = "document_ready_bridge"
    }

    /// A read-only readiness snapshot for diagnostics and surface-health output.
    public struct Snapshot: Sendable, Equatable {
        /// The currently observed WebView generation, if one is bound.
        public let instanceID: UUID?

        /// Whether a readiness signal has arrived for ``instanceID``.
        public let isReady: Bool

        /// The callback that most recently established readiness.
        public let signal: Signal?

        /// Creates a readiness snapshot.
        /// - Parameters:
        ///   - instanceID: Currently observed WebView generation, if one is bound.
        ///   - isReady: Whether that generation has produced a readiness signal.
        ///   - signal: Callback that most recently established readiness.
        public init(instanceID: UUID?, isReady: Bool, signal: Signal?) {
            self.instanceID = instanceID
            self.isReady = isReady
            self.signal = signal
        }
    }

    private var observedInstanceID: UUID?
    private var committedInstanceID: UUID?
    private var readinessSignal: Signal?
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
                readinessSignal = .nativeCommit
                finishWaiters(with: .committed)
            }
            return
        }

        finishWaiters(with: .superseded)
        observedInstanceID = instanceID
        committedInstanceID = hasCommittedDocument ? instanceID : nil
        readinessSignal = hasCommittedDocument ? .nativeCommit : nil
    }

    /// Records a navigation commit when it belongs to the currently bound browser instance.
    /// - Parameter instanceID: Identity captured when the navigation delegate was bound.
    public func didCommit(instanceID: UUID) {
        guard observedInstanceID == instanceID else { return }
        committedInstanceID = instanceID
        readinessSignal = .nativeCommit
        finishWaiters(with: .committed)
    }

    /// Records the isolated document-end bridge signal for the current WebView instance.
    ///
    /// This is a fallback for the narrow lifecycle window where the document is already
    /// executable but the navigation delegate callback was lost during a WebView rebind. The
    /// bridge lives in a private content world, so page JavaScript cannot synthesize this signal.
    /// - Parameter instanceID: Identity captured when the bridge handler was bound.
    public func didSignalDocumentReady(instanceID: UUID) {
        guard observedInstanceID == instanceID else { return }
        committedInstanceID = instanceID
        if readinessSignal == nil {
            readinessSignal = .documentReadyBridge
        }
        finishWaiters(with: .committed)
    }

    /// Returns the current readiness state without exposing mutable internals.
    public var snapshot: Snapshot {
        Snapshot(
            instanceID: observedInstanceID,
            isReady: observedInstanceID != nil && committedInstanceID == observedInstanceID,
            signal: readinessSignal
        )
    }

    /// Stops observing the current browser instance and cancels its pending waits.
    public func invalidate() {
        observedInstanceID = nil
        committedInstanceID = nil
        readinessSignal = nil
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
