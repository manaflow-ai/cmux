import CMUXMobileCore
import Foundation
import Observation

/// One visible workspace's presence model, owned by its UI lifetime.
@MainActor @Observable
public final class WorkspacePresenceSession {
    /// Whether the current connection has delivered an authoritative snapshot.
    public enum Phase: Equatable, Sendable { case unavailable, connecting, available }
    /// Current connection state; stale participants are always cleared on failure.
    public private(set) var phase: Phase = .unavailable
    /// The current complete participant list, never data from a previous room.
    public private(set) var participants: [WorkspacePresenceParticipant] = []
    /// Whether this view currently claims active viewing.
    public private(set) var isViewing = false
    @ObservationIgnored private let transport: any WorkspacePresenceConnecting
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connection: (any WorkspacePresenceConnection)?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var snapshotContinuations: [UUID: AsyncStream<[WorkspacePresenceParticipant]>.Continuation] = [:]
    private var revision: UInt64 = 0
    private var lastReceivedAt: Date?
    private var renewAfterMs = 15_000

    /// Creates a testable session with injected transport and lease clock.
    public init(transport: any WorkspacePresenceConnecting, clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.clock = clock
        self.now = now
    }

    /// Changes active viewing immediately, independent of the lease renewal cadence.
    /// - Parameter active: False when hidden, backgrounded or inactive.
    public func setViewing(_ active: Bool) {
        guard active != isViewing else { return }
        isViewing = active
        revision &+= 1
        sending?.cancel()
        guard let connection else { return }
        let revision = revision
        sending = Task {
            do { try await connection.sendViewing(active, revision: revision) }
            catch { connection.close() }
        }
    }

    /// Streams authoritative participant replacements for UI projections.
    /// The current value is emitted immediately, so a consumer never needs a
    /// separate race-prone read before subscribing.
    public func snapshots() -> AsyncStream<[WorkspacePresenceParticipant]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(participants)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.snapshotContinuations[id] = nil
                }
            }
        }
    }

    /// Runs until the owning view cancels; reconnects only within captured auth authority.
    /// - Parameters:
    ///   - scope: Canonical workspace identity.
    ///   - accessToken: Revalidates the captured account/team generation before returning a token.
    ///   - isCurrent: Synchronous authority fence, also checked after each received frame.
    public func run(scope: WorkspacePresenceScope, accessToken: @escaping @MainActor () async -> String?, isCurrent: @escaping @MainActor () -> Bool) async {
        stop()
        let epoch = UUID()
        generation = epoch
        var backoff: TimeInterval = 1
        defer { if generation == epoch { stop() } }
        while !Task.isCancelled && generation == epoch && isCurrent() {
            phase = .connecting
            var retryDelay = backoff
            do {
                guard let token = await accessToken(), !Task.isCancelled, generation == epoch, isCurrent() else { return }
                let opened = try await transport.connect(scope: scope, accessToken: token)
                guard !Task.isCancelled, generation == epoch, isCurrent() else { opened.close(); return }
                connection = opened
                lastReceivedAt = now()
                defer { opened.close() }
                try await opened.sendViewing(isViewing, revision: revision)
                let renewal = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.generation == epoch, isCurrent() else { opened.close(); return }
                        do {
                            try await clock.sleep(for: .milliseconds(self.renewAfterMs))
                            try await opened.sendViewing(self.isViewing, revision: self.revision)
                        } catch {
                            opened.close()
                            return
                        }
                    }
                }
                defer { renewal.cancel(); opened.close() }
                while !Task.isCancelled {
                    let snapshot = try await opened.receive()
                    guard self.generation == epoch, isCurrent() else { return }
                    guard snapshot.isValid(for: scope) else { throw WorkspacePresenceError.invalidSnapshot }
                    lastReceivedAt = now()
                    renewAfterMs = snapshot.renewAfterMs
                    participants = snapshot.participants
                    for continuation in snapshotContinuations.values {
                        continuation.yield(participants)
                    }
                    phase = .available
                }
            } catch is CancellationError { return }
            catch WorkspacePresenceError.retryAfter(let delay) { retryDelay = max(retryDelay, delay) }
            catch { }
            guard generation == epoch else { return }
            connection = nil
            participants = []
            phase = .unavailable
            guard !Task.isCancelled, isCurrent() else { return }
            // Intentional bounded reconnect backoff; cancellation closes the old socket first.
            do { try await clock.sleep(for: .seconds(retryDelay)) } catch { return }
            backoff = min(backoff * 2, 60)
        }
    }

    /// Retires all connection work synchronously before another room/account can render.
    public func stop() {
        generation = UUID()
        sending?.cancel()
        sending = nil
        connection?.close()
        connection = nil
        participants = []
        for continuation in snapshotContinuations.values {
            continuation.yield([])
        }
        phase = .unavailable
    }
}
