import Foundation

/// Owns all local listener scans so PortScanner consumers share one bounded
/// libproc capture and a short-lived superset cache.
actor PortScanSnapshotStore {
    typealias Now = @Sendable () async -> Date
    typealias Capture = @Sendable (Set<Int>) async -> [Int: Set<Int>]

    private struct CachedScan {
        let requestedPIDs: Set<Int>
        let portsByPID: [Int: Set<Int>]
        let storedAt: Date
        let metricsToken: ProcessPerformanceMetricToken
    }

    private struct InFlightScan {
        let id: UInt64
        let requestedPIDs: Set<Int>
        let task: Task<[Int: Set<Int>], Never>
        let metricsToken: ProcessPerformanceMetricToken
    }

    private let now: Now
    private let capture: Capture
    private let metrics: ProcessPerformanceMetrics
    private var cached: CachedScan?
    private var inFlight: InFlightScan?
    private var pendingPIDs: Set<Int> = []
    private var nextCaptureID: UInt64 = 0

    init(
        now: @escaping Now = { Date() },
        capture: @escaping Capture = { pids in PortScanner.scanListeningPorts(pids: pids) },
        metrics: ProcessPerformanceMetrics = .shared
    ) {
        self.now = now
        self.capture = capture
        self.metrics = metrics
    }

    func snapshot(
        pids: Set<Int>,
        maximumAge: TimeInterval
    ) async -> [Int: Set<Int>] {
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
                    metrics.recordLsofReuse(.inFlight, token: active.metricsToken)
                    let portsByPID = await active.task.value
                    await finishCapture(active, portsByPID: portsByPID)
                    return portsByPID
                }

                pendingPIDs.formUnion(requestedPIDs)
                metrics.recordLsofCoalescedRequest(token: active.metricsToken)
                let portsByPID = await active.task.value
                await finishCapture(active, portsByPID: portsByPID)
                continue
            }

            pendingPIDs.formUnion(requestedPIDs)
            let capturePIDs = pendingPIDs
            pendingPIDs.removeAll(keepingCapacity: true)
            nextCaptureID &+= 1
            let id = nextCaptureID
            let capture = self.capture
            let metricsToken = metrics.lsofStarted(pidCount: capturePIDs.count)
            let task = Task.detached(priority: .utility) {
                await capture(capturePIDs)
            }
            let started = InFlightScan(
                id: id,
                requestedPIDs: capturePIDs,
                task: task,
                metricsToken: metricsToken
            )
            inFlight = started
            let portsByPID = await task.value
            await finishCapture(started, portsByPID: portsByPID)
            if capturePIDs.isSuperset(of: requestedPIDs) {
                return portsByPID
            }
        }
    }

    private func finishCapture(
        _ completed: InFlightScan,
        portsByPID: [Int: Set<Int>]
    ) async {
        let storedAt = await now()
        guard inFlight?.id == completed.id else { return }
        cached = CachedScan(
            requestedPIDs: completed.requestedPIDs,
            portsByPID: portsByPID,
            storedAt: storedAt,
            metricsToken: completed.metricsToken
        )
        inFlight = nil
        metrics.lsofCompleted(completed.metricsToken)
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
