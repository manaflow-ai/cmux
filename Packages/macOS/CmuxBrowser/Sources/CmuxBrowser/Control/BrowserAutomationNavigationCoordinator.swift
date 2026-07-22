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
        return ticket
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

    /// Records a cancellation only when it belongs to the exact active navigation.
    public func didCancel(instanceID: UUID, navigationID: ObjectIdentifier?) {
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
        if activeTicket == ticket {
            finish(ticket, with: Task.isCancelled ? .cancelled : outcome)
            ticket.transaction.discardTerminalOutcome()
        }
        return Task.isCancelled ? .cancelled : outcome
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
        activeTicket = nil
        activeNavigationID = nil
        activeTargetURL = nil
        allowsSameDocumentCompletion = false
        downloadPolicyNavigationID = nil
        ticket.transaction.finish(with: outcome)
    }
}
