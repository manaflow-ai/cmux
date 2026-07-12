import Foundation
import os

nonisolated struct CmuxTopProcessSnapshotRequirements: OptionSet, Sendable {
    let rawValue: UInt8

    static let processDetails = Self(rawValue: 1 << 0)
    static let cmuxScope = Self(rawValue: 1 << 1)
    static let basic: Self = []
}

actor CmuxTopProcessSnapshotStore {
    typealias Now = @Sendable () async -> Date
    typealias Capture = @Sendable (CmuxTopProcessSnapshotRequirements) async -> CmuxTopProcessSnapshot

    static let shared = CmuxTopProcessSnapshotStore()

    private struct CachedSnapshot {
        let snapshot: CmuxTopProcessSnapshot
        let requirements: CmuxTopProcessSnapshotRequirements
        let storedAt: Date
        let generation: UInt64
        let metricsToken: ProcessPerformanceMetricToken
    }

    private struct InFlightCapture {
        let id: UInt64
        let requirements: CmuxTopProcessSnapshotRequirements
        let task: Task<CmuxTopProcessSnapshot, Never>
        let metricsToken: ProcessPerformanceMetricToken
    }

    private let now: Now
    private let capture: Capture
    private let metrics: ProcessPerformanceMetrics
    private var cached: CachedSnapshot?
    private var inFlight: InFlightCapture?
    private var nextCaptureID: UInt64 = 0

    init(
        now: @escaping Now = { Date() },
        capture: @escaping Capture = { requirements in
            CmuxTopProcessSnapshot.capture(
                includeProcessDetails: requirements.contains(.processDetails),
                includeCMUXScope: requirements.contains(.cmuxScope)
            )
        },
        metrics: ProcessPerformanceMetrics = .shared
    ) {
        self.now = now
        self.capture = capture
        self.metrics = metrics
    }

    func snapshot(
        requirements: CmuxTopProcessSnapshotRequirements,
        maximumAge: TimeInterval,
        consumer: ProcessSnapshotConsumer = .unspecified
    ) async -> CmuxTopProcessSnapshot {
        metrics.recordProcessSnapshotRequest(consumer: consumer)
        let requestedAt = await now()
        if let cached = validCachedSnapshot(
            requirements: requirements,
            maximumAge: maximumAge,
            now: requestedAt
        ) {
            metrics.recordProcessSnapshotReuse(
                consumer: consumer,
                generation: cached.generation,
                source: .cache,
                token: cached.metricsToken
            )
            return cached.snapshot
        }

        while true {
            if let inFlight {
                let snapshot = await inFlight.task.value
                await finishCapture(inFlight, snapshot: snapshot)
                if inFlight.requirements.isSuperset(of: requirements) {
                    metrics.recordProcessSnapshotReuse(
                        consumer: consumer,
                        generation: inFlight.id,
                        source: .inFlight,
                        token: inFlight.metricsToken
                    )
                    return snapshot
                }
                let now = await now()
                if let cached = validCachedSnapshot(
                    requirements: requirements,
                    maximumAge: maximumAge,
                    now: now
                ) {
                    metrics.recordProcessSnapshotReuse(
                        consumer: consumer,
                        generation: cached.generation,
                        source: .cache,
                        token: cached.metricsToken
                    )
                    return cached.snapshot
                }
                continue
            }

            nextCaptureID &+= 1
            let id = nextCaptureID
            let capture = self.capture
            let metricsToken = metrics.processSnapshotCaptureStarted(
                generation: id,
                requirementsRawValue: requirements.rawValue
            )
            let task = Task.detached(priority: .utility) {
                await capture(requirements)
            }
            let started = InFlightCapture(
                id: id,
                requirements: requirements,
                task: task,
                metricsToken: metricsToken
            )
            inFlight = started
            let snapshot = await task.value
            await finishCapture(started, snapshot: snapshot)
            return snapshot
        }
    }

    private func finishCapture(
        _ completed: InFlightCapture,
        snapshot: CmuxTopProcessSnapshot
    ) async {
        let storedAt = await now()
        guard inFlight?.id == completed.id else { return }
        cached = CachedSnapshot(
            snapshot: snapshot,
            requirements: completed.requirements,
            storedAt: storedAt,
            generation: completed.id,
            metricsToken: completed.metricsToken
        )
        inFlight = nil
        metrics.processSnapshotCaptureCompleted(
            completed.metricsToken,
            generation: completed.id,
            processCount: snapshot.processesByPID.count
        )
    }

    private func validCachedSnapshot(
        requirements: CmuxTopProcessSnapshotRequirements,
        maximumAge: TimeInterval,
        now: Date
    ) -> CachedSnapshot? {
        guard let cached,
              cached.requirements.isSuperset(of: requirements),
              now.timeIntervalSince(cached.storedAt) <= max(0, maximumAge) else {
            return nil
        }
        return cached
    }
}

nonisolated extension CmuxTopProcessSnapshot {
    /// Measured escape hatch for lifecycle and compatibility code that cannot await
    /// ``CmuxTopProcessSnapshotStore``. Live and periodic consumers must use the actor.
    static func captureSynchronouslyForCompatibility(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        metrics: ProcessPerformanceMetrics = .shared,
        captureBody: (Bool, Bool) -> CmuxTopProcessSnapshot = { includeProcessDetails, includeCMUXScope in
            CmuxTopProcessSnapshot.capture(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            )
        }
    ) -> CmuxTopProcessSnapshot {
        let generation = metrics.nextSynchronousCaptureGeneration()
        var requirements = CmuxTopProcessSnapshotRequirements.basic
        if includeProcessDetails { requirements.insert(.processDetails) }
        if includeCMUXScope { requirements.insert(.cmuxScope) }
        let token = metrics.processSnapshotCaptureStarted(
            generation: generation,
            requirementsRawValue: requirements.rawValue
        )
        let snapshot = captureBody(includeProcessDetails, includeCMUXScope)
        metrics.processSnapshotCaptureCompleted(
            token,
            generation: generation,
            processCount: snapshot.processesByPID.count
        )
        return snapshot
    }
}
