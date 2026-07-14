import Foundation

/// Applies one bounded liveness deadline before asking a browser surface to replace an unresponsive WebView.
///
/// The watchdog owns no WebKit state. Its caller supplies the callback-based liveness probe and the
/// synchronous recovery mutation, keeping the package testable without launching AppKit or WebKit.
/// A completed probe always wins over recovery, while a missing callback reaches the injected deadline.
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

    private enum ProbeSignal: Sendable {
        case responsive
        case timedOut
        case cancelled
    }

    private let probeTimeout: Duration
    private let sleep: Sleep

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

    /// Probes the browser automation pipeline once and recovers only when that callback misses its deadline.
    /// - Parameters:
    ///   - probe: Starts a cheap, side-effect-free liveness operation.
    ///   - recover: Replaces the WebView if it is still the instance observed by the failed operation.
    /// - Returns: The liveness or recovery outcome.
    public func recoverIfUnresponsive(
        probe: Probe,
        recover: Recovery
    ) async -> BrowserAutomationRecoveryOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let (signals, continuation) = AsyncStream.makeStream(
            of: ProbeSignal.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        probe {
            continuation.yield(.responsive)
            continuation.finish()
        }

        let signal = await withTaskGroup(of: ProbeSignal.self, returning: ProbeSignal.self) { group in
            group.addTask {
                var iterator = signals.makeAsyncIterator()
                return await iterator.next() ?? .cancelled
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
}
