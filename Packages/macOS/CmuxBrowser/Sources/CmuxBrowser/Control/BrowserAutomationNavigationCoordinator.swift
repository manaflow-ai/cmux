public import Foundation

/// Owns the lifecycle of browser-automation navigations for one browser panel.
///
/// A transaction is associated with the exact navigation identity returned by the load call.
/// Document loads complete only for a delegate callback carrying that identity. Same-document
/// loads complete only for a trusted main-frame event that reaches the exact target URL.
@MainActor
public final class BrowserAutomationNavigationCoordinator {
    /// Cancellable timing source used for the terminal-navigation deadline.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let navigationTimeout: Duration
    private let sleep: Sleep
    private var observedInstanceID: UUID?
    private var activeTicket: BrowserAutomationNavigationTicket?
    private var activeNavigationID: ObjectIdentifier?
    private var activeTargetURL: URL?
    private var allowsSameDocumentCompletion = false
    private var downloadPolicyNavigationID: ObjectIdentifier?
    private var pendingReplacementNavigationID: ObjectIdentifier?
    private var externalNavigationTask: Task<Void, Never>?
    private var externalNavigationTicket: BrowserAutomationNavigationTicket?
    // Swift tasks cannot force-terminate an engine callback that ignores
    // cancellation. Keep one cancelled operation slot owned until that task
    // exits, and fail closed while it is occupied so repeated retries cannot
    // accumulate permanently retained engine tasks.
    private var externalNavigationOperationTask: Task<Void, Never>?
    private var externalNavigationOperationID: UUID?

    /// Creates a coordinator with a bounded continuous-clock navigation deadline.
    public init(navigationTimeout: Duration = .seconds(15)) {
        self.navigationTimeout = navigationTimeout
        let clock = ContinuousClock()
        self.sleep = { duration in
            try await clock.sleep(for: duration)
        }
    }

    /// Creates a coordinator with an injected timing source for deterministic tests.
    public init(
        navigationTimeout: Duration = .seconds(15),
        sleep: @escaping Sleep
    ) {
        self.navigationTimeout = navigationTimeout
        self.sleep = sleep
    }

    /// Starts observing a WebView instance and supersedes a transaction from an older instance.
    public func bind(to instanceID: UUID) {
        guard observedInstanceID != instanceID else { return }
        cancelExternalNavigation()
        if let activeTicket {
            finish(activeTicket, with: .superseded)
        }
        observedInstanceID = instanceID
    }

    /// Begins a transaction for the currently bound WebView instance.
    ///
    /// - Parameters:
    ///   - instanceID: Identity of the WebView instance that will perform the navigation.
    ///   - targetURL: Display URL the navigation must reach.
    ///   - allowsSameDocumentCompletion: Whether a trusted same-document event may finish
    ///     the transaction. Pass `false` for reloads and app-owned error documents.
    /// - Returns: A ticket that observes the transaction's one terminal outcome.
    public func begin(
        instanceID: UUID,
        targetURL: URL? = nil,
        allowsSameDocumentCompletion: Bool = false
    ) -> BrowserAutomationNavigationTicket {
        cancelExternalNavigation()
        if let activeTicket {
            finish(activeTicket, with: .superseded)
        }

        let ticket = BrowserAutomationNavigationTicket(instanceID: instanceID)
        guard observedInstanceID == instanceID else {
            ticket.transaction.finish(with: .superseded)
            return ticket
        }
        activeTicket = ticket
        activeNavigationID = nil
        activeTargetURL = targetURL
        self.allowsSameDocumentCompletion = allowsSameDocumentCompletion
        downloadPolicyNavigationID = nil
        pendingReplacementNavigationID = nil
        return ticket
    }

    /// Runs an engine-owned navigation under the same bounded ticket deadline
    /// used by WebKit delegate navigations.
    ///
    /// The operation is retained and cancelled when the panel closes, a newer
    /// navigation supersedes it, or the caller's wait reaches its deadline.
    /// This prevents a stalled CDP target from leaving an unowned task behind.
    ///
    /// - Parameters:
    ///   - ticket: The active external-navigation ticket.
    ///   - operation: The engine operation and its terminal load wait.
    public func startExternalNavigation(
        _ ticket: BrowserAutomationNavigationTicket,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard activeTicket == ticket else { return }
        cancelExternalNavigation()
        guard externalNavigationOperationID == nil else {
            finish(ticket, with: .timedOut)
            return
        }
        let operationID = UUID()
        externalNavigationTicket = ticket
        externalNavigationOperationID = operationID
        externalNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.runExternalNavigationWithDeadline(operation, operationID: operationID) {
            case .committed:
                self.finish(ticket, with: .committed)
            case .timedOut:
                self.finish(ticket, with: .timedOut)
            case .cancelled:
                self.finish(ticket, with: .cancelled)
            case .failed:
                self.finish(ticket, with: .failed("Browser operation failed"))
            }
        }
    }

    /// Cancels a retained engine operation after its caller has stopped waiting.
    public func cancelExternalNavigation(
        _ ticket: BrowserAutomationNavigationTicket? = nil
    ) {
        guard ticket == nil || externalNavigationTicket == ticket else { return }
        externalNavigationTask?.cancel()
        externalNavigationTask = nil
        externalNavigationTicket = nil
        externalNavigationOperationTask?.cancel()
        if externalNavigationOperationTask == nil {
            externalNavigationOperationID = nil
        }
    }

    /// Associates the load call's returned navigation identity with its transaction.
    public func didStart(
        _ ticket: BrowserAutomationNavigationTicket,
        navigationID: ObjectIdentifier?
    ) {
        guard activeTicket == ticket else { return }
        guard let navigationID else {
            finish(ticket, with: .notStarted)
            return
        }
        activeNavigationID = navigationID
    }

    /// Associates a deferred or replacement load's returned navigation identity.
    public func didAssociate(
        instanceID: UUID,
        navigationID: ObjectIdentifier?,
        targetURL: URL? = nil
    ) {
        guard let navigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID else {
            return
        }
        if activeNavigationID == nil {
            if let activeTargetURL, targetURL != activeTargetURL {
                finish(activeTicket, with: .superseded)
                return
            }
            activeNavigationID = navigationID
        }
    }

    /// Records the provisional delegate start for an associated navigation.
    public func didStart(
        instanceID: UUID,
        navigationID: ObjectIdentifier?,
        targetURL: URL? = nil
    ) {
        didAssociate(instanceID: instanceID, navigationID: navigationID, targetURL: targetURL)
    }

    /// Keeps an active transaction pending while an app-owned replacement is prepared.
    ///
    /// Policy-interruption and cancellation callbacks for the exact navigation being replaced
    /// are ignored until
    /// ``didReplaceNavigation(instanceID:replacedNavigationID:replacementNavigationID:)``
    /// supplies the replacement or reports that no replacement started.
    ///
    /// - Parameters:
    ///   - instanceID: Identity of the WebView instance performing the load.
    ///   - navigationID: Identity of the navigation the app is about to cancel.
    public func willReplaceNavigation(
        instanceID: UUID,
        navigationID: ObjectIdentifier?
    ) {
        guard let navigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == navigationID else {
            return
        }
        pendingReplacementNavigationID = navigationID
        downloadPolicyNavigationID = nil
    }

    /// Transfers an active transaction to an app-owned replacement navigation.
    ///
    /// The replacement is accepted only when the transaction is still bound to
    /// the exact navigation authorized by ``willReplaceNavigation(instanceID:navigationID:)``.
    /// A `nil` replacement terminates the pending transaction as cancelled.
    ///
    /// - Parameters:
    ///   - instanceID: Identity of the WebView instance performing both loads.
    ///   - replacedNavigationID: Identity of the navigation cancelled by the app.
    ///   - replacementNavigationID: Identity returned by the replacement load.
    public func didReplaceNavigation(
        instanceID: UUID,
        replacedNavigationID: ObjectIdentifier?,
        replacementNavigationID: ObjectIdentifier?
    ) {
        guard let replacedNavigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == replacedNavigationID,
              pendingReplacementNavigationID == replacedNavigationID else {
            return
        }
        pendingReplacementNavigationID = nil
        guard let replacementNavigationID else {
            finish(activeTicket, with: .cancelled)
            return
        }
        activeNavigationID = replacementNavigationID
        downloadPolicyNavigationID = nil
    }

    /// Resolves a reload after WebKit returns no navigation identity.
    ///
    /// A document-less new tab is already in its requested state. Active recovery/deferred
    /// signals keep the transaction open for the delegate callback that binds its real load;
    /// every other nil return means WebKit did not start the requested reload.
    public func didReturnNoNavigation(
        _ ticket: BrowserAutomationNavigationTicket,
        hasCurrentHistoryItem: Bool,
        isShowingNewTabPage: Bool,
        waitsForDeferredNavigation: Bool
    ) {
        guard activeTicket == ticket, activeNavigationID == nil else { return }
        guard !waitsForDeferredNavigation else { return }
        let outcome: BrowserAutomationNavigationOutcome =
            !hasCurrentHistoryItem && isShowingNewTabPage ? .committed : .notStarted
        finish(ticket, with: outcome)
    }

    /// Completes the active transaction after WebKit reports a same-document navigation.
    ///
    /// The owning WebView must call this only from a trusted main-frame same-document event.
    /// Presentation URL observation is not a navigation lifecycle signal and must not call this API.
    public func didFinishSameDocumentNavigation(instanceID: UUID, url: URL?) {
        guard let url,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID != nil,
              allowsSameDocumentCompletion,
              let activeTargetURL,
              let observedNavigationURL = BrowserAutomationNavigationURL(url),
              let targetNavigationURL = BrowserAutomationNavigationURL(activeTargetURL),
              observedNavigationURL == targetNavigationURL else {
            return
        }
        finish(activeTicket, with: .committed)
    }

    /// Authorizes a download outcome for the exact provisional navigation whose response policy changed.
    ///
    /// - Parameters:
    ///   - instanceID: Identity of the WebView instance receiving the response.
    ///   - navigationID: Identity of the provisional navigation whose response became a download.
    public func didChooseDownloadPolicy(instanceID: UUID, navigationID: ObjectIdentifier?) {
        guard let navigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == navigationID else {
            return
        }
        downloadPolicyNavigationID = navigationID
    }

    /// Completes an exact policy-interrupted navigation and reports whether it was an authorized download.
    ///
    /// WebKit error 102 covers every policy interruption, so only a preceding response-download decision
    /// for the same navigation identity is a successful download. All other matching interruptions
    /// are cancellations.
    ///
    /// - Parameters:
    ///   - instanceID: Identity of the WebView instance reporting the interruption.
    ///   - navigationID: Identity of the provisional navigation interrupted by policy.
    /// - Returns: `true` only when the exact navigation had an authorized response-download decision.
    @discardableResult
    public func didInterruptByPolicyChange(
        instanceID: UUID,
        navigationID: ObjectIdentifier?
    ) -> Bool {
        guard let navigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == navigationID else {
            return false
        }
        guard pendingReplacementNavigationID != navigationID else { return false }
        let isDownload = downloadPolicyNavigationID == navigationID
        finish(activeTicket, with: isDownload ? .downloaded : .cancelled)
        return isDownload
    }

    /// Records a commit only when it belongs to the exact active navigation.
    public func didCommit(instanceID: UUID, navigationID: ObjectIdentifier?) {
        finishMatching(instanceID: instanceID, navigationID: navigationID, with: .committed)
    }

    /// Records a failure only when it belongs to the exact active navigation.
    public func didFail(instanceID: UUID, navigationID: ObjectIdentifier?, message: String) {
        finishMatching(instanceID: instanceID, navigationID: navigationID, with: .failed(message))
    }

    /// Completes a transaction whose navigation identity is owned by an
    /// engine adapter rather than a WebKit delegate.
    ///
    /// Chromium reports navigation completion through CDP, so it cannot
    /// provide a ``WKNavigation`` identity. The adapter still uses this same
    /// coordinator and ticket lifecycle so callers observe identical terminal
    /// outcomes across engines.
    public func finishExternally(
        _ ticket: BrowserAutomationNavigationTicket,
        with outcome: BrowserAutomationNavigationOutcome
    ) {
        finish(ticket, with: outcome)
    }

    /// Records a cancellation only when it belongs to the exact active navigation.
    public func didCancel(instanceID: UUID, navigationID: ObjectIdentifier?) {
        guard pendingReplacementNavigationID != navigationID else { return }
        finishMatching(instanceID: instanceID, navigationID: navigationID, with: .cancelled)
    }

    /// Cancels a transaction that no longer has a caller waiting for it.
    public func cancel(_ ticket: BrowserAutomationNavigationTicket) {
        guard activeTicket == ticket else { return }
        finish(ticket, with: .cancelled)
    }

    /// Cancels the active transaction and stops observing the current WebView instance.
    public func invalidate() {
        if let activeTicket {
            finish(activeTicket, with: .cancelled)
        }
        observedInstanceID = nil
    }

    /// Waits for the exact navigation to commit or reach another terminal delegate outcome.
    public func wait(
        for ticket: BrowserAutomationNavigationTicket
    ) async -> BrowserAutomationNavigationOutcome {
        guard !Task.isCancelled else {
            cancel(ticket)
            ticket.transaction.discardTerminalOutcome()
            return .cancelled
        }
        if let completed = ticket.transaction.takeTerminalOutcome() {
            return completed
        }
        guard activeTicket == ticket else { return .superseded }

        let events = ticket.transaction.makeEventStream()
        let outcome = await withTaskGroup(
            of: BrowserAutomationNavigationOutcome.self,
            returning: BrowserAutomationNavigationOutcome.self
        ) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next() ?? .cancelled
            }
            group.addTask { [navigationTimeout, sleep] in
                do {
                    try await sleep(navigationTimeout)
                } catch {
                    return .cancelled
                }
                return Task.isCancelled ? .cancelled : .timedOut
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            ticket.transaction.cancelWaiter()
            await group.waitForAll()
            return first
        }

        ticket.transaction.discardTerminalOutcome()
        if outcome == .timedOut || outcome == .cancelled || Task.isCancelled {
            cancelExternalNavigation(ticket)
        }
        if activeTicket == ticket {
            finish(ticket, with: Task.isCancelled ? .cancelled : outcome)
            ticket.transaction.discardTerminalOutcome()
        }
        return Task.isCancelled ? .cancelled : outcome
    }

    private func runExternalNavigationWithDeadline(
        _ operation: @escaping @MainActor () async throws -> Void,
        operationID: UUID
    ) async -> ExternalNavigationRaceResult {
        guard externalNavigationOperationID == operationID, !Task.isCancelled else {
            return .cancelled
        }
        let (events, continuation) = AsyncStream.makeStream(
            of: ExternalNavigationRaceResult.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let operationTask = Task { @MainActor [weak self] in
            defer { self?.externalNavigationOperationDidFinish(operationID) }
            do {
                try await operation()
                continuation.yield(Task.isCancelled ? .cancelled : .committed)
            } catch is CancellationError {
                if !Task.isCancelled {
                    continuation.yield(.cancelled)
                }
            } catch let error as ChromiumBrowserDiagnostic where error == .navigationTimedOut {
                _ = error
                continuation.yield(Task.isCancelled ? .cancelled : .timedOut)
            } catch {
                continuation.yield(Task.isCancelled ? .cancelled : .failed)
            }
        }
        externalNavigationOperationTask = operationTask
        let timeoutTask = Task { @MainActor [navigationTimeout, sleep] in
            do {
                try await sleep(navigationTimeout)
                try Task.checkCancellation()
                continuation.yield(.timedOut)
            } catch is CancellationError {
                if !Task.isCancelled {
                    continuation.yield(.cancelled)
                }
            } catch {
                continuation.yield(Task.isCancelled ? .cancelled : .failed)
            }
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
        return await withTaskCancellationHandler(operation: {
            var iterator = events.makeAsyncIterator()
            return await iterator.next() ?? .cancelled
        }, onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        })
    }

    private func externalNavigationOperationDidFinish(_ operationID: UUID) {
        guard externalNavigationOperationID == operationID else { return }
        externalNavigationOperationTask = nil
        externalNavigationOperationID = nil
    }

    private func finishMatching(
        instanceID: UUID,
        navigationID: ObjectIdentifier?,
        with outcome: BrowserAutomationNavigationOutcome
    ) {
        guard let navigationID,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == navigationID else {
            return
        }
        finish(activeTicket, with: outcome)
    }

    private func finish(
        _ ticket: BrowserAutomationNavigationTicket,
        with outcome: BrowserAutomationNavigationOutcome
    ) {
        guard activeTicket == ticket else { return }
        if externalNavigationTicket == ticket {
            cancelExternalNavigation(ticket)
        }
        activeTicket = nil
        activeNavigationID = nil
        activeTargetURL = nil
        allowsSameDocumentCompletion = false
        downloadPolicyNavigationID = nil
        pendingReplacementNavigationID = nil
        ticket.transaction.finish(with: outcome)
    }
}
