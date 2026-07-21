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
    private var terminalOutcomes: [UUID: BrowserAutomationNavigationOutcome] = [:]
    private var waiters: [
        UUID: AsyncStream<BrowserAutomationNavigationOutcome>.Continuation
    ] = [:]

    /// Creates a coordinator with a bounded continuous-clock navigation deadline.
    public init(navigationTimeout: Duration = .seconds(8)) {
        self.navigationTimeout = navigationTimeout
        let clock = ContinuousClock()
        self.sleep = { duration in
            try await clock.sleep(for: duration)
        }
    }

    /// Creates a coordinator with an injected timing source for deterministic tests.
    public init(
        navigationTimeout: Duration = .seconds(8),
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
    public func begin(instanceID: UUID) -> BrowserAutomationNavigationTicket {
        if let activeTicket {
            finish(activeTicket, with: .superseded)
        }

        let ticket = BrowserAutomationNavigationTicket(instanceID: instanceID)
        guard observedInstanceID == instanceID else {
            terminalOutcomes[ticket.transactionID] = .superseded
            return ticket
        }
        activeTicket = ticket
        activeNavigationID = nil
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
        if let outcome = terminalOutcomes.removeValue(forKey: ticket.transactionID) {
            return outcome
        }
        guard activeTicket == ticket else { return .superseded }

        let (events, continuation) = AsyncStream.makeStream(
            of: BrowserAutomationNavigationOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        waiters[ticket.transactionID] = continuation
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

        waiters.removeValue(forKey: ticket.transactionID)
        terminalOutcomes.removeValue(forKey: ticket.transactionID)
        if activeTicket == ticket {
            finish(ticket, with: Task.isCancelled ? .cancelled : outcome)
            terminalOutcomes.removeValue(forKey: ticket.transactionID)
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
        terminalOutcomes[ticket.transactionID] = outcome
        if let waiter = waiters.removeValue(forKey: ticket.transactionID) {
            waiter.yield(outcome)
            waiter.finish()
        }
    }
}
