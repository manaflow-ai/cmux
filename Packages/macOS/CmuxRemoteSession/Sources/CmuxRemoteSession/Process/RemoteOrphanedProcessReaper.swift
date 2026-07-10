internal import Darwin
internal import Foundation

/// Process-wide actor that shares native orphan-process captures across remote reconnects.
public actor RemoteOrphanedProcessReaper: RemoteOrphanedProcessReaping {
    typealias Signal = @Sendable (_ pid: Int, _ signal: Int32) async -> Int32
    typealias Validate = @Sendable (RemoteOrphanProcessSnapshot) async -> Bool

    private struct CacheEntry: Sendable {
        let snapshots: [RemoteOrphanProcessSnapshot]
        let capturedAtNanoseconds: UInt64
        let metricsToken: RemoteOrphanProcessCaptureMetricToken
    }

    private struct InFlightCapture: Sendable {
        let id: UInt64
        let metricsToken: RemoteOrphanProcessCaptureMetricToken
        let task: Task<[RemoteOrphanProcessSnapshot], Never>
    }

    private let capturer: any RemoteOrphanProcessSnapshotCapturing
    private let maximumAgeNanoseconds: UInt64
    private let nowNanoseconds: @Sendable () -> UInt64
    private let signal: Signal
    private let validate: Validate
    private nonisolated let metrics = RemoteOrphanProcessMetricSink()
    private var nextCaptureID: UInt64 = 0
    private var cacheEntry: CacheEntry?
    private var inFlightCapture: InFlightCapture?

    /// Creates a native libproc-backed reaper with a one-second snapshot cache.
    public init() {
        self.capturer = NativeRemoteOrphanProcessSnapshotCapturer()
        self.maximumAgeNanoseconds = 1_000_000_000
        self.nowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
        self.signal = { Darwin.kill(pid_t($0), $1) }
        self.validate = { NativeRemoteOrphanProcessSnapshotCapturer.isStillSameProcess($0) }
    }

    init(
        capturer: any RemoteOrphanProcessSnapshotCapturing,
        maximumAgeNanoseconds: UInt64,
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        signal: @escaping Signal,
        validate: @escaping Validate = { _ in true }
    ) {
        self.capturer = capturer
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
        self.nowNanoseconds = nowNanoseconds
        self.signal = signal
        self.validate = validate
    }

    public func reap(destination: String, relayPort: Int?, persistentDaemonSlot: String?) async {
        guard !Task.isCancelled else { return }
        let requestMetricsToken = metrics.reapStarted()
        let snapshots = await snapshots()
        guard !Task.isCancelled else { return }
        let candidates = RemoteSessionCoordinator.orphanedCMUXRemoteSSHSnapshots(
            snapshots,
            destination: destination,
            relayPort: relayPort,
            persistentDaemonSlot: persistentDaemonSlot
        )
        var signalsSent = 0
        var rejectedReusedPIDs = 0
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard await validate(candidate) else {
                rejectedReusedPIDs += 1
                continue
            }
            guard !Task.isCancelled else { break }
            if await signal(candidate.pid, SIGTERM) == 0 {
                signalsSent += 1
            }
        }
        metrics.reapCompleted(
            requestMetricsToken,
            candidatePIDs: candidates.count,
            signalsSent: signalsSent,
            rejectedReusedPIDs: rejectedReusedPIDs
        )
    }

    /// Returns current capture, reuse, and signal counters.
    public nonisolated func metricsSnapshot() -> RemoteOrphanProcessSnapshotMetrics {
        metrics.snapshot()
    }

    /// Resets counters without invalidating a reusable process snapshot.
    public nonisolated func resetMetrics() {
        metrics.reset()
    }

    private func snapshots() async -> [RemoteOrphanProcessSnapshot] {
        let requestedAtNanoseconds = nowNanoseconds()
        if let cacheEntry,
           elapsedNanoseconds(
               from: cacheEntry.capturedAtNanoseconds,
               to: requestedAtNanoseconds
           ) < maximumAgeNanoseconds {
            metrics.recordCacheReuse(cacheEntry.metricsToken)
            return cacheEntry.snapshots
        }
        if let inFlightCapture {
            metrics.recordInFlightReuse(inFlightCapture.metricsToken)
            return await inFlightCapture.task.value
        }

        nextCaptureID &+= 1
        let id = nextCaptureID
        let capturer = self.capturer
        let metricsToken = metrics.captureStarted(at: requestedAtNanoseconds)
        let task = Task {
            await capturer.capture()
        }
        let capture = InFlightCapture(
            id: id,
            metricsToken: metricsToken,
            task: task
        )
        inFlightCapture = capture

        let result = await task.value
        guard inFlightCapture?.id == id else { return result }
        let completedAtNanoseconds = nowNanoseconds()
        cacheEntry = CacheEntry(
            snapshots: result,
            capturedAtNanoseconds: completedAtNanoseconds,
            metricsToken: capture.metricsToken
        )
        inFlightCapture = nil
        metrics.captureCompleted(
            capture.metricsToken,
            at: completedAtNanoseconds,
            processCount: result.count
        )
        return result
    }

    private func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}
