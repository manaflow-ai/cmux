import Foundation

/// Owns all local listener scans so PortScanner consumers share one bounded
/// libproc capture and a short-lived superset cache.
actor PortScanSnapshotStore {
    typealias Now = @Sendable () async -> Date
    typealias Capture = @Sendable (Set<Int>) async -> [Int: Set<Int>]
    typealias ProvenancedCapture = @Sendable (Set<Int>) async -> (
        portsByPID: [Int: Set<Int>],
        proof: ProcessPerformanceCaptureProof
    )

    private struct CachedScan {
        let requestedPIDs: Set<Int>
        let portsByPID: [Int: Set<Int>]
        let storedAt: Date
        let metricsToken: ProcessPerformanceMetricToken
    }

    private struct InFlightScan {
        let id: UInt64
        let requestedPIDs: Set<Int>
        let task: Task<(
            portsByPID: [Int: Set<Int>],
            proof: ProcessPerformanceCaptureProof
        ), Never>
        let metricsToken: ProcessPerformanceMetricToken
    }

    private struct PerformanceExercise {
        let gate: ProcessPerformanceExerciseGate
        var captureID: UInt64?
        var joined = false
        var proof: ProcessPerformanceCaptureProof?
    }

    private let now: Now
    private let capture: ProvenancedCapture
    private let metrics: ProcessPerformanceMetrics
    private var cached: CachedScan?
    private var inFlight: InFlightScan?
    private var pendingPIDs: Set<Int> = []
    private var nextCaptureID: UInt64 = 0
    private var performanceExercise: PerformanceExercise?

    init(
        now: @escaping Now = { Date() },
        capture: @escaping Capture,
        metrics: ProcessPerformanceMetrics = .shared
    ) {
        self.now = now
        self.capture = { pids in
            (await capture(pids), .libproc)
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
        pids: Set<Int>,
        maximumAge: TimeInterval
    ) async -> [Int: Set<Int>] {
        if let exercise = performanceExercise,
           !ProcessPerformanceExerciseContext.isListenerExerciseRequest {
            await exercise.gate.waitUntilFinished()
            return await snapshot(pids: pids, maximumAge: maximumAge)
        }
        let requestedPIDs = Set(pids.filter { $0 > 0 })
        guard !requestedPIDs.isEmpty else { return [:] }

        while true {
            let requestedAt = await now()
            if let cached = validCachedScan(
                covering: requestedPIDs,
                maximumAge: maximumAge,
                now: requestedAt
            ) {
                metrics.recordLsofReuse(.cache, token: cached.metricsToken)
                return cached.portsByPID
            }

            if let active = inFlight {
                if active.requestedPIDs.isSuperset(of: requestedPIDs) {
                    if ProcessPerformanceExerciseContext.isListenerExerciseRequest,
                       performanceExercise?.captureID == active.id {
                        performanceExercise?.joined = true
                        await performanceExercise?.gate.recordJoin()
                    }
                    metrics.recordLsofReuse(.inFlight, token: active.metricsToken)
                    let captureResult = await active.task.value
                    await finishCapture(active, captureResult: captureResult)
                    return captureResult.portsByPID
                }

                pendingPIDs.formUnion(requestedPIDs)
                metrics.recordLsofCoalescedRequest(token: active.metricsToken)
                let captureResult = await active.task.value
                await finishCapture(active, captureResult: captureResult)
                continue
            }

            pendingPIDs.formUnion(requestedPIDs)
            let capturePIDs = pendingPIDs
            pendingPIDs.removeAll(keepingCapacity: true)
            nextCaptureID &+= 1
            let id = nextCaptureID
            let capture = self.capture
            let exerciseGate = ProcessPerformanceExerciseContext.isListenerExerciseRequest
                ? performanceExercise?.gate
                : nil
            if exerciseGate != nil {
                performanceExercise?.captureID = id
                await exerciseGate?.recordGeneration(id)
            }
            let metricsToken = metrics.lsofStarted(pidCount: capturePIDs.count)
            let task = Task.detached(priority: .utility) {
                let result = await capture(capturePIDs)
                if let exerciseGate {
                    await exerciseGate.waitForCaptureRelease()
                }
                return result
            }
            let started = InFlightScan(
                id: id,
                requestedPIDs: capturePIDs,
                task: task,
                metricsToken: metricsToken
            )
            inFlight = started
            let captureResult = await task.value
            await finishCapture(started, captureResult: captureResult)
            if capturePIDs.isSuperset(of: requestedPIDs) {
                return captureResult.portsByPID
            }
        }
    }

    /// Forces two real listener requests through the normal sharing branch.
    func performanceMetricsExercise(pids: Set<Int>) async -> (
        proof: ProcessPerformanceCaptureProof,
        sharedResult: Bool
    )? {
        while let active = inFlight {
            let captureResult = await active.task.value
            await finishCapture(active, captureResult: captureResult)
        }
        cached = nil
        pendingPIDs.removeAll(keepingCapacity: true)

        let capturePIDs = Set(pids.filter { $0 > 0 })
        let gate = ProcessPerformanceExerciseGate()
        performanceExercise = PerformanceExercise(gate: gate)
        return await withTaskCancellationHandler {
            await runPerformanceMetricsExercise(pids: capturePIDs, gate: gate)
        } onCancel: {
            Task { await self.cancelPerformanceExercise(gate) }
        }
    }

    private func runPerformanceMetricsExercise(
        pids: Set<Int>,
        gate: ProcessPerformanceExerciseGate
    ) async -> (proof: ProcessPerformanceCaptureProof, sharedResult: Bool)? {
        let primary = Task {
            await ProcessPerformanceExerciseContext.$isListenerExerciseRequest.withValue(true) {
                await self.snapshot(pids: pids, maximumAge: 0)
            }
        }
        guard await gate.waitForGeneration() != nil else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        let secondary = Task {
            await ProcessPerformanceExerciseContext.$isListenerExerciseRequest.withValue(true) {
                await self.snapshot(pids: pids, maximumAge: 0)
            }
        }
        guard await gate.waitForJoinCount(1) else {
            await cancelPerformanceExercise(gate)
            _ = await primary.value
            _ = await secondary.value
            return nil
        }
        guard !Task.isCancelled else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        await gate.releaseCapture()
        let primaryResult = await primary.value
        let secondaryResult = await secondary.value
        guard !Task.isCancelled else {
            await cancelPerformanceExercise(gate)
            return nil
        }
        let exercise = performanceExercise
        await gate.finish()
        performanceExercise = nil
        guard let proof = exercise?.proof else { return nil }
        return (proof, primaryResult == secondaryResult)
    }

    private func cancelPerformanceExercise(_ gate: ProcessPerformanceExerciseGate) async {
        guard performanceExercise?.gate === gate else { return }
        await gate.releaseCapture()
        await gate.finish()
        performanceExercise = nil
    }

    private func finishCapture(
        _ completed: InFlightScan,
        captureResult: (
            portsByPID: [Int: Set<Int>],
            proof: ProcessPerformanceCaptureProof
        )
    ) async {
        let storedAt = await now()
        guard inFlight?.id == completed.id else { return }
        if performanceExercise?.captureID == completed.id {
            performanceExercise?.proof = captureResult.proof
        }
        cached = CachedScan(
            requestedPIDs: completed.requestedPIDs,
            portsByPID: captureResult.portsByPID,
            storedAt: storedAt,
            metricsToken: completed.metricsToken
        )
        inFlight = nil
        metrics.lsofCompleted(completed.metricsToken, proof: captureResult.proof)
    }

    private func validCachedScan(
        covering requestedPIDs: Set<Int>,
        maximumAge: TimeInterval,
        now: Date
    ) -> CachedScan? {
        guard let cached,
              cached.requestedPIDs.isSuperset(of: requestedPIDs),
              now.timeIntervalSince(cached.storedAt) <= max(0, maximumAge) else {
            return nil
        }
        return cached
    }
}
