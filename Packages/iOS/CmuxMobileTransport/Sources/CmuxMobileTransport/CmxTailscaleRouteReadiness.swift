internal import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation

/// Route preparation ended because the tunnel never became usable, not because
/// the request itself was invalid.
enum CmxTailscaleReadinessError: Error, Equatable, Sendable {
    /// The readiness deadline elapsed before an observation satisfied the
    /// route proof. Carries the last transient proof failure (nil when no
    /// path observation arrived at all) so diagnostics can say why.
    case deadlineExpired(lastFailure: CmxTailscaleRouteProofError?)
}

/// One path observation captured atomically at the platform boundary: the
/// proof-facing content plus the platform interface token the dialer needs
/// for each interface identity. `sequence` records capture order so a
/// reordered hop onto the readiness actor cannot regress to an older state.
struct CmxTailscalePathObservation<Interface: Sendable>: Sendable {
    let sequence: UInt64
    let pathSatisfied: Bool
    let interfaces: [CmxNetworkInterfaceIdentity: Interface]
    let systemInterfaces: [CmxTailscaleInterfaceSnapshot]
}

/// A proof plus the platform interface token it was proven against, taken
/// from the same observation so the pair can never disagree.
struct CmxTailscaleReadyRoute<Interface: Sendable>: Sendable {
    let proof: CmxTailscaleRouteProof
    let interface: Interface
}

/// The single owner of Tailscale route readiness: the latest path observation,
/// its proof generation, and every waiter parked on the next observation.
///
/// `prepare(request:)` retries transient proof failures on each new
/// observation and gives up only when the injected clock's readiness deadline
/// elapses, so a QR scanned while the tunnel is still coming up succeeds the
/// moment the tunnel interface appears instead of failing on the startup
/// snapshot. Waiters resume with `CancellationError` when their task is
/// cancelled, so a closed transport can never strand a suspended preparation.
///
/// Generic over the platform interface token so the lifecycle is testable
/// without constructing `NWPath`/`NWInterface`.
actor CmxTailscaleRouteReadiness<Interface: Sendable> {
    private struct Latest {
        let generation: UInt64
        let observation: CmxTailscalePathObservation<Interface>
    }

    private let clock: any Clock<Duration>
    private let readinessDeadline: Duration
    private var latest: Latest?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Waiter IDs whose cancellation handler ran before registration; the
    /// registration throws instead of suspending.
    private var cancelledWaiterIDs: Set<UUID> = []
    private var lastTransientFailures: [UUID: CmxTailscaleRouteProofError] = [:]

    init(clock: any Clock<Duration>, readinessDeadline: Duration) {
        self.clock = clock
        self.readinessDeadline = readinessDeadline
    }

    /// Test-only visibility into how many callers are parked on the next
    /// observation.
    var pendingWaiterCount: Int { waiters.count }

    /// Records a newer observation and wakes every parked waiter. Observations
    /// older than the latest one are dropped: capture order is authoritative,
    /// not arrival order. The proof generation advances only when proof-facing
    /// content changes, so duplicate monitor callbacks cannot invalidate a
    /// proven route.
    func ingest(_ observation: CmxTailscalePathObservation<Interface>) {
        if let latest, observation.sequence <= latest.observation.sequence {
            return
        }
        let generation: UInt64
        if let latest {
            generation = Self.contentMatches(latest.observation, observation)
                ? latest.generation
                : Self.nextGeneration(after: latest.generation)
        } else {
            generation = 1
        }
        let changed = latest.map { $0.generation != generation } ?? true
        latest = Latest(generation: generation, observation: observation)
        if changed, let snapshot = latestSnapshot {
            MobileDebugLog.shared.append(
                Self.logLine("tailscale.path_update", snapshot: snapshot)
            )
        }
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Returns a proven route bound to the observation it was proven against.
    /// Waits through transient readiness failures until the deadline; throws
    /// `CmxTailscaleReadinessError.deadlineExpired` when the tunnel never
    /// becomes usable, non-transient proof failures immediately, and
    /// `CancellationError` when the caller's task is cancelled.
    func prepare(
        request: CmxByteTransportRequest
    ) async throws -> CmxTailscaleReadyRoute<Interface> {
        let attemptID = UUID()
        defer { lastTransientFailures[attemptID] = nil }
        return try await withThrowingTaskGroup(
            of: CmxTailscaleReadyRoute<Interface>?.self
        ) { group in
            group.addTask {
                try await self.readyRoute(request: request, attemptID: attemptID)
            }
            group.addTask { () -> CmxTailscaleReadyRoute<Interface>? in
                try await self.clock.sleep(
                    for: self.readinessDeadline,
                    tolerance: nil
                )
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let route = first else {
                throw CmxTailscaleReadinessError.deadlineExpired(
                    lastFailure: lastTransientFailures[attemptID]
                )
            }
            return route
        }
    }

    /// Validates a proof against the latest observation. The caller supplies
    /// the connection-path snapshot; the system authority refreshes the latest
    /// observation first so this cannot pass against a stale one.
    func validate(
        proof: CmxTailscaleRouteProof,
        connectionPath: CmxTailscaleConnectionPathSnapshot,
        phase: CmxTailscaleRouteValidationPhase = .established
    ) throws {
        guard let snapshot = latestSnapshot else {
            throw CmxTailscaleRouteProofError.pathUnavailable
        }
        try CmxTailscaleRouteProofValidator().validate(
            proof: proof,
            authoritySnapshot: snapshot,
            connectionPath: connectionPath,
            phase: phase
        )
    }

    private func readyRoute(
        request: CmxByteTransportRequest,
        attemptID: UUID
    ) async throws -> CmxTailscaleReadyRoute<Interface>? {
        while true {
            try Task.checkCancellation()
            let observedSequence = latest?.observation.sequence
            if let latest {
                do {
                    guard let snapshot = latestSnapshot else {
                        throw CmxTailscaleRouteProofError.pathUnavailable
                    }
                    let proof = try CmxTailscaleRouteProofValidator().prepare(
                        request: request,
                        snapshot: snapshot
                    )
                    guard let interface = latest.observation.interfaces[proof.interface] else {
                        // The validator only selects identities present in the
                        // observation, so this cannot fire; classified transient
                        // to fail toward the deadline instead of aborting.
                        throw CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable
                    }
                    MobileDebugLog.shared.append(
                        "tailscale.prepare.success interface=\(proof.interface.name):\(proof.interface.index) generation=\(proof.generation)"
                    )
                    return CmxTailscaleReadyRoute(proof: proof, interface: interface)
                } catch let error as CmxTailscaleRouteProofError
                    where error.isTransientReadinessFailure
                {
                    lastTransientFailures[attemptID] = error
                    MobileDebugLog.shared.append(
                        "tailscale.prepare.waiting reason=\(String(describing: error)) generation=\(latest.generation)"
                    )
                }
            } else {
                MobileDebugLog.shared.append(
                    "tailscale.prepare.waiting reason=no_path_observation"
                )
            }
            try await nextObservation(after: observedSequence)
        }
    }

    /// Parks until an observation newer than `sequence` has been ingested.
    /// Re-checks inside the continuation body so an observation landing
    /// between the caller's read and registration can never be slept through,
    /// and resumes with `CancellationError` when the waiting task is
    /// cancelled.
    private func nextObservation(after sequence: UInt64?) async throws {
        let waiterID = UUID()
        defer { cancelledWaiterIDs.remove(waiterID) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if latest?.observation.sequence != sequence {
                    continuation.resume()
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiterIDs.insert(id)
        }
    }

    private var latestSnapshot: CmxTailscaleAuthoritySnapshot? {
        guard let latest else { return nil }
        return CmxTailscaleAuthoritySnapshot(
            generation: latest.generation,
            pathSatisfied: latest.observation.pathSatisfied,
            availableInterfaces: Set(latest.observation.interfaces.keys),
            systemInterfaces: latest.observation.systemInterfaces
        )
    }

    private static func contentMatches(
        _ lhs: CmxTailscalePathObservation<Interface>,
        _ rhs: CmxTailscalePathObservation<Interface>
    ) -> Bool {
        lhs.pathSatisfied == rhs.pathSatisfied
            && Set(lhs.interfaces.keys) == Set(rhs.interfaces.keys)
            && Set(lhs.systemInterfaces) == Set(rhs.systemInterfaces)
    }

    private static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation == .max ? 1 : generation + 1
    }

    private static func logLine(
        _ prefix: String,
        snapshot: CmxTailscaleAuthoritySnapshot
    ) -> String {
        let interfaces = snapshot.systemInterfaces.map { interface in
            "\(interface.identity.name):\(interface.identity.index),up=\(interface.isUp),running=\(interface.isRunning),tailnet_addrs=\(interface.tailnetAddresses.count)"
        }.sorted().joined(separator: ";")
        let available = snapshot.availableInterfaces
            .map { "\($0.name):\($0.index)" }
            .sorted()
            .joined(separator: ",")
        return "\(prefix) generation=\(snapshot.generation) path_satisfied=\(snapshot.pathSatisfied) available_interfaces=\(available) system_interfaces=\(interfaces)"
    }
}
