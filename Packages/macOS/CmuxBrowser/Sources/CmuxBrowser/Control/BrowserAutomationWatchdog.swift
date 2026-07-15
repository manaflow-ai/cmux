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
    private var inFlightWaiters: [CheckedContinuation<BrowserAutomationRecoveryOutcome, Never>] = []

    /// Creates a browser automation watchdog.
    /// - Parameters:
    ///   - probeTimeout: Maximum time to wait for a liveness callback before recovery. Defaults to one second.
    ///   - sleep: Cancellable timing source. Tests can inject an immediate or controlled deadline.
    public init(
        probeTimeout: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }
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
            return await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }

        if inFlightObservedInstanceID != nil {
            finishInFlightRecovery(with: .superseded)
        }

        inFlightObservedInstanceID = observedInstanceID
        let outcome = await performRecovery(probes: probes, recover: recover)
        guard inFlightObservedInstanceID == observedInstanceID else { return .superseded }

        finishInFlightRecovery(with: outcome)
        return outcome
    }

    private func performRecovery(
        probes: [Probe],
        recover: Recovery
    ) async -> BrowserAutomationRecoveryOutcome {
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
            return first
        }

        guard !Task.isCancelled else { return .cancelled }
        switch signal {
        case .responsive:
            return .responsive
        case .timedOut:
            return recover() ? .recovered : .superseded
        case .cancelled:
            return .cancelled
        }
    }

    private func finishInFlightRecovery(with outcome: BrowserAutomationRecoveryOutcome) {
        let waiters = inFlightWaiters
        inFlightWaiters.removeAll()
        inFlightObservedInstanceID = nil
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }
}
