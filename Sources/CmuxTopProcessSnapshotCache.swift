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
    typealias ProvenancedCapture = @Sendable (CmuxTopProcessSnapshotRequirements) async -> (
        snapshot: CmuxTopProcessSnapshot,
        proof: ProcessPerformanceCaptureProof
    )

    static let shared = CmuxTopProcessSnapshotStore(captureWithProof: { requirements in
        CmuxTopProcessSnapshot.captureWithPerformanceProof(
            includeProcessDetails: requirements.contains(.processDetails),
            includeCMUXScope: requirements.contains(.cmuxScope)
        )
    })

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
        let task: Task<(
            snapshot: CmuxTopProcessSnapshot,
            proof: ProcessPerformanceCaptureProof
        ), Never>
        let metricsToken: ProcessPerformanceMetricToken
    }

    private struct PerformanceExercise {
        let gate: ProcessPerformanceExerciseGate
        var generation: UInt64?
        var secondaryJoins = 0
        var proof: ProcessPerformanceCaptureProof?
    }

    private let now: Now
    private let capture: ProvenancedCapture
    private let metrics: ProcessPerformanceMetrics
    private var cached: CachedSnapshot?
    private var inFlight: InFlightCapture?
    private var nextCaptureID: UInt64 = 0
    private var performanceExercise: PerformanceExercise?

    init(
        now: @escaping Now = { Date() },
        capture: @escaping Capture,
        metrics: ProcessPerformanceMetrics = .shared
    ) {
        self.now = now
        self.capture = { requirements in
            (await capture(requirements), .libproc)
        }
        self.metrics = metrics
    }

    init(
        now: @escaping Now = { Date() },
        captureWithProof: @escaping ProvenancedCapture,
        metrics: ProcessPerformanceMetrics = .shared
    ) {
        self.now = now
        self.capture = captureWithProof
        self.metrics = metrics
    }

    func snapshot(
        requirements: CmuxTopProcessSnapshotRequirements,
        maximumAge: TimeInterval,
        consumer: ProcessSnapshotConsumer = .unspecified
    ) async -> CmuxTopProcessSnapshot {
        if let exercise = performanceExercise,
           consumer != .performanceExercisePrimary,
           consumer != .performanceExerciseSecondary {
            await exercise.gate.waitUntilFinished()
            return await snapshot(
                requirements: requirements,
                maximumAge: maximumAge,
                consumer: consumer
            )
        }
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
                if consumer == .performanceExerciseSecondary,
                   performanceExercise?.generation == inFlight.id {
                    performanceExercise?.secondaryJoins += 1
                    await performanceExercise?.gate.recordJoin()
                }
                let captureResult = await inFlight.task.value
                await finishCapture(inFlight, captureResult: captureResult)
                if inFlight.requirements.isSuperset(of: requirements) {
                    metrics.recordProcessSnapshotReuse(
                        consumer: consumer,
                        generation: inFlight.id,
                        source: .inFlight,
                        token: inFlight.metricsToken
                    )
                    return captureResult.snapshot
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
            let exerciseGate = consumer == .performanceExercisePrimary
                ? performanceExercise?.gate
                : nil
            if exerciseGate != nil {
                performanceExercise?.generation = id
                await exerciseGate?.recordGeneration(id)
            }
            let metricsToken = metrics.processSnapshotCaptureStarted(
                generation: id,
                requirementsRawValue: requirements.rawValue
            )
            let task = Task.detached(priority: .utility) {
                let result = await capture(requirements)
                if let exerciseGate {
                    await exerciseGate.waitForCaptureRelease()
                }
                return result
            }
            let started = InFlightCapture(
                id: id,
                requirements: requirements,
                task: task,
                metricsToken: metricsToken
            )
            inFlight = started
            let captureResult = await task.value
            await finishCapture(started, captureResult: captureResult)
            return captureResult.snapshot
        }
    }

    /// Forces real production snapshot requests through one fresh generation.
    /// The barrier holds only the diagnostic capture result so every secondary
    /// request reaches the normal in-flight sharing branch before completion.
    func performanceMetricsExercise(requestCount: Int) async -> (
        measurementEpoch: UInt64,
        generation: UInt64,
        processCount: Int,
        proof: ProcessPerformanceCaptureProof,
        sharedSnapshotIdentity: Bool
    )? {
        while let active = inFlight {
            let captureResult = await active.task.value
            await finishCapture(active, captureResult: captureResult)
        }
        cached = nil
        let startingMetrics = metrics.snapshot()
        guard startingMetrics.enabled, startingMetrics.measurementEpoch > 0 else {
            return nil
        }

        let boundedRequestCount = min(max(requestCount, 2), 8)
        let gate = ProcessPerformanceExerciseGate()
        performanceExercise = PerformanceExercise(gate: gate)
        return await withTaskCancellationHandler {
            await runPerformanceMetricsExercise(
                requestCount: boundedRequestCount,
                measurementEpoch: startingMetrics.measurementEpoch,
                gate: gate
            )
        } onCancel: {
            Task { await self.cancelPerformanceExercise(gate) }
        }
    }

    private func runPerformanceMetricsExercise(
        requestCount: Int,
        measurementEpoch: UInt64,
        gate: ProcessPerformanceExerciseGate
    ) async -> (
        measurementEpoch: UInt64,
        generation: UInt64,
        processCount: Int,
        proof: ProcessPerformanceCaptureProof,
        sharedSnapshotIdentity: Bool
    )? {
        let requirements: CmuxTopProcessSnapshotRequirements = [.processDetails, .cmuxScope]
        let primary = Task {
            await self.snapshot(
                requirements: requirements,
                maximumAge: 0,
                consumer: .performanceExercisePrimary
            )
        }
        guard await gate.waitForGeneration() != nil else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        let secondaries = (1..<requestCount).map { _ in
            Task {
                await self.snapshot(
                    requirements: requirements,
                    maximumAge: 0,
                    consumer: .performanceExerciseSecondary
                )
            }
        }
        guard await gate.waitForJoinCount(requestCount - 1) else {
            await cancelPerformanceExercise(gate)
            _ = await primary.value
            for secondary in secondaries { _ = await secondary.value }
            return nil
        }
        guard !Task.isCancelled else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        await gate.releaseCapture()
        let primarySnapshot = await primary.value
        var sharedSnapshotIdentity = true
        for secondary in secondaries {
            sharedSnapshotIdentity = await secondary.value === primarySnapshot && sharedSnapshotIdentity
        }
        guard !Task.isCancelled else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        let exercise = performanceExercise
        await gate.finish()
        performanceExercise = nil
        guard let exercise,
              let generation = exercise.generation,
              let proof = exercise.proof else { return nil }
        let processCount = primarySnapshot.processesByPID.count
        let completedMetrics = metrics.snapshot()
        guard processCount > 0,
              completedMetrics.enabled,
              completedMetrics.measurementEpoch == measurementEpoch,
              let generationMetrics = completedMetrics.generations[generation],
              generationMetrics.started == 1,
              generationMetrics.completed == 1,
              generationMetrics.processCount == processCount else {
            return nil
        }
        return (
            measurementEpoch,
            generation,
            processCount,
            proof,
            sharedSnapshotIdentity
        )
    }

    private func cancelPerformanceExercise(_ gate: ProcessPerformanceExerciseGate) async {
        guard performanceExercise?.gate === gate else { return }
        await gate.releaseCapture()
        await gate.finish()
        performanceExercise = nil
    }

    private func finishCapture(
        _ completed: InFlightCapture,
        captureResult: (
            snapshot: CmuxTopProcessSnapshot,
            proof: ProcessPerformanceCaptureProof
        )
    ) async {
        let storedAt = await now()
        guard inFlight?.id == completed.id else { return }
        if performanceExercise?.generation == completed.id {
            performanceExercise?.proof = captureResult.proof
        }
        cached = CachedSnapshot(
            snapshot: captureResult.snapshot,
            requirements: completed.requirements,
            storedAt: storedAt,
            generation: completed.id,
            metricsToken: completed.metricsToken
        )
        inFlight = nil
        metrics.processSnapshotCaptureCompleted(
            completed.metricsToken,
            generation: completed.id,
            processCount: captureResult.snapshot.processesByPID.count,
            proof: captureResult.proof
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
        captureWithProof: (Bool, Bool) -> (
            snapshot: CmuxTopProcessSnapshot,
            proof: ProcessPerformanceCaptureProof
        ) = {
            includeProcessDetails, includeCMUXScope in
            CmuxTopProcessSnapshot.captureWithPerformanceProof(
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
        let capture = captureWithProof(includeProcessDetails, includeCMUXScope)
        metrics.processSnapshotCaptureCompleted(
            token,
            generation: generation,
            processCount: capture.snapshot.processesByPID.count,
            proof: capture.proof
        )
        return capture.snapshot
    }
}
