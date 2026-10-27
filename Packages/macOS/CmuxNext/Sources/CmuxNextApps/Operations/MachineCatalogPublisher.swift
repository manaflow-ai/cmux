import CmuxNextCompat
import CmuxNextDaemon
public import Observation
public import CmuxNextWakeups

/// Follows observed route changes and publishes them through one existing local connection.
///
/// No idle polling, owner start or reconnect occurs. Newer snapshots supersede and cancel
/// older attempts; the native sequence fence prevents a delayed older frame rolling back
/// a newer publication. An empty snapshot withdraws all remote routes on the live lease.
@MainActor
@Observable
public final class MachineCatalogPublisher {
    private let source: @MainActor @Sendable () -> MachineCatalogSource?
    private let backoff: Backoff
    private let clock: any Clock<Duration>
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private(set) var sending: Task<Void, Never>?
    private struct Lease: Equatable {
        let owner: ResourceID
        let writer: ObjectIdentifier
        let epoch: Int
        init(_ source: MachineCatalogSource) {
            owner = source.owner; writer = ObjectIdentifier(source.writer); epoch = source.epoch
        }
    }
    private var lease: Lease?
    private(set) var current: MachineCatalogSource?
    private var sequence: UInt64 = 0
    private(set) var publishedSequence: UInt64?
    private(set) var publishedOwner: ResourceID?

    /// Creates an event-driven publisher; call ``start()`` after composition.
    /// - Parameters:
    ///   - source: Reads observable registry, identity, admission and handshake state.
    ///   - backoff: Spacing after an actual competing-publisher or timeout refusal.
    ///   - clock: Cancellable retry clock; tests inject a controlled clock.
    public init(source: @escaping @MainActor @Sendable () -> MachineCatalogSource?,
                backoff: Backoff = .init(initial: .milliseconds(500), maximum: .seconds(30)),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        self.backoff = backoff
        self.clock = clock
    }

    nonisolated deinit { following?.cancel(); sending?.cancel() }

    /// Starts one observation stream; repeated starts have no effect.
    public func start() {
        guard following == nil else { return }
        // task-owner: this publisher owns one event-driven registry watch, cancelled by stop/deinit.
        following = Task { [weak self, source] in
            for await value in ObservationStream(source) {
                guard !Task.isCancelled else { return }
                self?.submit(value)
            }
        }
    }

    /// Stops observations and pending requests. The daemon retires the lease with its connection.
    /// Callers withdrawing routes while staying connected supply an empty snapshot before stopping.
    public func stop() {
        following?.cancel()
        following = nil
        sending?.cancel()
        sending = nil
        current = nil
        publishedSequence = nil
        publishedOwner = nil
        // Keep the sequence: restarting on a still-live connection must not reuse it.
    }

    private func submit(_ value: MachineCatalogSource?) {
        guard current != value else { return }
        if let value {
            let nextLease = Lease(value)
            if lease != nextLease { sequence = 0; lease = nextLease }
        }
        current = value
        sending?.cancel()
        publishedSequence = nil
        publishedOwner = nil
        guard let value, sequence < UInt64.max else { sending = nil; return }
        sequence += 1
        let next = sequence
        let request = MachineCatalogPublishRequest(expectedMachineID: value.owner, sequence: next, machines: value.machines)
        // task-owner: newest snapshot owns this bounded request/retry chain; a change or stop cancels it.
        sending = Task { [weak self, backoff, clock] in
            var backoff = backoff
            // wakeup-allow: backoff: every retry awaits the request and a Backoff after a real refusal; fatal errors end the chain.
            while !Task.isCancelled {
                guard self?.admit(value, sequence: next) == true else { return }
                do {
                    try await value.writer.publishMachineCatalog(request)
                    guard !Task.isCancelled, self?.admit(value, sequence: next) == true else { return }
                    self?.publishedSequence = next
                    self?.publishedOwner = value.owner
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self?.admit(value, sequence: next) == true,
                          Self.retryable(error) else { return }
                    // concurrency-allow: Backoff waits only after a real refusal; this is not a poll period.
                    do { try await backoff.wait(owner: "MachineCatalogPublisher.publish", clock: clock) } catch { return }
                }
            }
        }
    }

    /// Rechecks the observed source before each send, retry and acknowledgement.
    private func admit(_ expected: MachineCatalogSource, sequence: UInt64) -> Bool {
        guard current == expected, self.sequence == sequence else { return false }
        let latest = source()
        guard latest == expected else { submit(latest); return false }
        return true
    }

    private static func retryable(_ error: any Error) -> Bool {
        guard let error = error as? DaemonError else { return false }
        switch error {
        case .timedOut: return true
        case .command(_, _, let code, _, _): return code == "machine_catalog.taken"
        default: return false
        }
    }

}
