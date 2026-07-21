public import Foundation

/// Owns the lifecycle of browser-automation navigations for one browser panel.
///
/// A transaction is associated with the exact navigation identity returned by the load call.
/// Only a delegate callback for that identity can complete it, preventing an error-page commit
/// or an older in-flight navigation from being acknowledged as the requested document.
@MainActor
public final class BrowserAutomationNavigationCoordinator {
    /// Cancellable timing source used for the terminal-navigation deadline.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let navigationTimeout: Duration
    private let sleep: Sleep
    private var observedInstanceID: UUID?
    private var activeTicket: BrowserAutomationNavigationTicket?
    private var activeNavigationID: ObjectIdentifier?
    private var activeNavigationBeganProvisionally = false
    private var activeTargetURL: URL?
    private var terminalOutcome: (
        ticket: BrowserAutomationNavigationTicket,
        outcome: BrowserAutomationNavigationOutcome
    )?
    private var waiter: (
        transactionID: UUID,
        continuation: AsyncStream<BrowserAutomationNavigationOutcome>.Continuation
    )?

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
    public func begin(
        instanceID: UUID,
        targetURL: URL? = nil
    ) -> BrowserAutomationNavigationTicket {
        if let activeTicket {
            finish(activeTicket, with: .superseded)
        }

        let ticket = BrowserAutomationNavigationTicket(instanceID: instanceID)
        // One panel has one authoritative automation navigation. Once a newer
        // transaction begins, an abandoned older outcome is only superseded.
        terminalOutcome = nil
        guard observedInstanceID == instanceID else {
            terminalOutcome = (ticket, .superseded)
            return ticket
        }
        activeTicket = ticket
        activeNavigationID = nil
        activeNavigationBeganProvisionally = false
        activeTargetURL = targetURL
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

    /// Records a provisional delegate start, binding a deferred or replacement load when needed.
    public func didStart(
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
        if activeNavigationID == navigationID {
            activeNavigationBeganProvisionally = true
        }
    }

    /// Releases the current navigation identity while a policy flow waits to start its replacement.
    @discardableResult
    public func prepareForNavigationReplacement(
        instanceID: UUID,
        targetURL: URL? = nil
    ) -> Bool {
        guard let activeTicket, activeTicket.instanceID == instanceID else { return false }
        activeNavigationID = nil
        activeNavigationBeganProvisionally = false
        if let targetURL {
            activeTargetURL = targetURL
        }
        return true
    }

    /// Completes a reload that has no document and therefore requires no WebKit navigation.
    public func didCompleteWithoutNavigation(_ ticket: BrowserAutomationNavigationTicket) {
        guard activeTicket == ticket, activeNavigationID == nil else { return }
        finish(ticket, with: .committed)
    }

    /// Terminates a deferred replacement when policy resolution starts no navigation.
    public func didNotStart(instanceID: UUID) {
        guard let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID == nil else {
            return
        }
        finish(activeTicket, with: .notStarted)
    }

    /// Completes the active transaction when WebKit changes to its target URL without a document commit.
    ///
    /// The owning WebView must call this only for an authoritative URL change outside a provisional
    /// main-frame load, which is WebKit's observable signal for a same-document navigation.
    public func didReachSameDocumentURL(instanceID: UUID, url: URL?) {
        guard let url,
              let activeTicket,
              activeTicket.instanceID == instanceID,
              activeNavigationID != nil,
              !activeNavigationBeganProvisionally,
              activeTargetURL == url else {
            return
        }
        finish(activeTicket, with: .committed)
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
            return .cancelled
        }
        if let completed = terminalOutcome, completed.ticket == ticket {
            terminalOutcome = nil
            return completed.outcome
        }
        guard activeTicket == ticket else { return .superseded }

        let (events, continuation) = AsyncStream.makeStream(
            of: BrowserAutomationNavigationOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        waiter = (ticket.transactionID, continuation)
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
            continuation.finish()
            await group.waitForAll()
            return first
        }

        if waiter?.transactionID == ticket.transactionID {
            waiter = nil
        }
        if terminalOutcome?.ticket == ticket {
            terminalOutcome = nil
        }
        if activeTicket == ticket {
            finish(ticket, with: Task.isCancelled ? .cancelled : outcome)
            terminalOutcome = nil
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
        activeNavigationBeganProvisionally = false
        activeTargetURL = nil
        terminalOutcome = (ticket, outcome)
        if let waiter, waiter.transactionID == ticket.transactionID {
            self.waiter = nil
            waiter.continuation.yield(outcome)
            waiter.continuation.finish()
        }
    }
}
