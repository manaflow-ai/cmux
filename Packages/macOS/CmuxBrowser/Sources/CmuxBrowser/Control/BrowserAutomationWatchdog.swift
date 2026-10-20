public import Foundation

/// Applies one bounded liveness deadline before asking a browser surface to replace an unresponsive WebView.
///
/// The watchdog owns no WebKit state. Its caller supplies the callback-based liveness probe and the
/// synchronous recovery mutation, keeping the package testable without launching AppKit or WebKit.
/// Every supplied probe must complete before the pipeline is considered responsive; one missing callback
/// reaches the injected deadline even when another WebKit callback channel remains alive.
@MainActor
public final class BrowserAutomationWatchdog {
    /// Starts a liveness probe and invokes its completion when the browser automation pipeline responds.
    public typealias Probe = @MainActor (
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    /// Replaces the observed WebView, returning `false` when another lifecycle path already superseded it.
    public typealias Recovery = @MainActor () -> Bool

    /// Cancellable timing source used for the liveness deadline.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let probeTimeout: Duration
    private let sleep: Sleep
    private var inFlightObservedInstanceID: UUID?
    private var inFlightWaiters: [
        UUID: AsyncStream<BrowserAutomationRecoveryOutcome>.Continuation
    ] = [:]

    /// Creates a browser automation watchdog using a continuous-clock deadline.
    /// - Parameter probeTimeout: Maximum time to wait for a liveness callback before recovery.
    public init(probeTimeout: Duration = .seconds(1)) {
        self.probeTimeout = probeTimeout
        let clock = ContinuousClock()
        self.sleep = { duration in
            try await clock.sleep(for: duration)
        }
    }

    /// Creates a browser automation watchdog with an injected timing source.
    /// - Parameters:
    ///   - probeTimeout: Maximum time to wait for a liveness callback before recovery.
    ///   - sleep: Cancellable timing source. Tests can inject an immediate or controlled deadline.
    public init(
        probeTimeout: Duration = .seconds(1),
        sleep: @escaping Sleep
    ) {
        self.probeTimeout = probeTimeout
        self.sleep = sleep
    }

    /// Probes every relevant browser automation callback channel and recovers when any callback misses its deadline.
    ///
    /// Concurrent checks for the same browser instance join the first check and receive its outcome. A check for
    /// a newer instance supersedes callers waiting on the old instance without starting duplicate recovery work.
    /// - Parameters:
    ///   - observedInstanceID: Stable identity of the browser instance whose failed operation triggered the check.
    ///   - probes: Cheap, side-effect-free liveness operations. An empty collection is treated as responsive.
    ///   - recover: Replaces the WebView if it is still the instance observed by the failed operation.
    /// - Returns: The liveness or recovery outcome.
    public func recoverIfUnresponsive(
        observedInstanceID: UUID,
        probes: [Probe],
        recover: Recovery
    ) async -> BrowserAutomationRecoveryOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !probes.isEmpty else { return .responsive }

        if inFlightObservedInstanceID == observedInstanceID {
            return await waitForInFlightRecovery(observedInstanceID: observedInstanceID)
        }

        if inFlightObservedInstanceID != nil {
            finishInFlightRecovery(with: .superseded)
        }

        inFlightObservedInstanceID = observedInstanceID
        let signal = await performLivenessCheck(probes: probes)
        guard inFlightObservedInstanceID == observedInstanceID else { return .superseded }

        let outcome: BrowserAutomationRecoveryOutcome
        switch signal {
        case .responsive:
            outcome = .responsive
        case .timedOut:
            outcome = recover() ? .recovered : .superseded
        case .cancelled:
            outcome = .cancelled
        }
        finishInFlightRecovery(with: outcome)
        return outcome
    }

    /// Invalidates the current check and cancels callers waiting on its shared result.
    public func invalidate() {
        guard inFlightObservedInstanceID != nil else { return }
        finishInFlightRecovery(with: .cancelled)
    }

    private func performLivenessCheck(
        probes: [Probe]
    ) async -> BrowserAutomationProbeSignal {
        let (signals, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingOldest(probes.count)
        )
        for (index, probe) in probes.enumerated() {
            probe {
                continuation.yield(index)
            }
        }

        let expectedProbeCount = probes.count
        let signal = await withTaskGroup(
            of: BrowserAutomationProbeSignal.self,
            returning: BrowserAutomationProbeSignal.self
        ) { group in
            group.addTask {
                var iterator = signals.makeAsyncIterator()
                var completedProbeIndexes = Set<Int>()
                while let index = await iterator.next() {
                    completedProbeIndexes.insert(index)
                    if completedProbeIndexes.count == expectedProbeCount {
                        return .responsive
                    }
                }
                return .cancelled
            }
            group.addTask { [probeTimeout, sleep] in
                do {
                    try await sleep(probeTimeout)
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

        return Task.isCancelled ? .cancelled : signal
    }

    private func waitForInFlightRecovery(
        observedInstanceID: UUID
    ) async -> BrowserAutomationRecoveryOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard inFlightObservedInstanceID == observedInstanceID else { return .superseded }

        let waiterID = UUID()
        let (events, continuation) = AsyncStream.makeStream(
            of: BrowserAutomationRecoveryOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        inFlightWaiters[waiterID] = continuation
        defer {
            inFlightWaiters.removeValue(forKey: waiterID)
            continuation.finish()
        }
        var iterator = events.makeAsyncIterator()
        return await iterator.next() ?? .cancelled
    }

    private func finishInFlightRecovery(with outcome: BrowserAutomationRecoveryOutcome) {
        let waiters = Array(inFlightWaiters.values)
        inFlightWaiters.removeAll()
        inFlightObservedInstanceID = nil
        for waiter in waiters {
            waiter.yield(outcome)
            waiter.finish()
        }
    }
}
