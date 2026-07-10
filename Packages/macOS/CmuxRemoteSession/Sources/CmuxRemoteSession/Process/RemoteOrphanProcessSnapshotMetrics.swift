internal import os

/// Runtime evidence for shared orphan-process discovery and cleanup.
public struct RemoteOrphanProcessSnapshotMetrics: Sendable, Equatable {
    /// Number of native process captures started.
    public let captureStarted: Int
    /// Number of native process captures completed.
    public let captureCompleted: Int
    /// Number of native captures currently running.
    public let captureInFlight: Int
    /// Highest number of simultaneous native captures.
    public let maximumCaptureInFlight: Int
    /// Total process records returned by completed captures.
    public let capturedProcessCount: Int
    /// Number of requests served from the bounded cache.
    public let cacheReuse: Int
    /// Number of requests that joined an existing capture.
    public let inFlightReuse: Int
    /// Number of orphan-cleanup requests received.
    public let reapRequests: Int
    /// Number of matching orphan PID candidates considered.
    public let candidatePIDs: Int
    /// Number of successful `SIGTERM` deliveries.
    public let signalsSent: Int
    /// Number of cached PID records rejected after identity revalidation.
    public let rejectedReusedPIDs: Int
    /// Total native capture time in milliseconds.
    public let captureDurationTotalMilliseconds: Double
    /// Longest native capture time in milliseconds.
    public let captureDurationMaximumMilliseconds: Double
    /// Subprocess launches used for process discovery. This is always zero.
    public let processLaunches: Int
}

struct RemoteOrphanProcessCaptureMetricToken: Sendable {
    let epoch: UInt64
    let startedAtNanoseconds: UInt64
}

struct RemoteOrphanProcessReapMetricToken: Sendable {
    let epoch: UInt64
}

/// Synchronous metrics seam for the app's synchronous DEBUG control RPC.
/// Only counters live behind this lock; snapshot capture and cache ownership
/// remain isolated to ``RemoteOrphanedProcessReaper``.
final class RemoteOrphanProcessMetricSink: @unchecked Sendable {
    private struct State {
        var epoch: UInt64
        var activeCaptureCount: Int
        var captureStarted = 0
        var captureCompleted = 0
        var maximumCaptureInFlight: Int
        var capturedProcessCount = 0
        var cacheReuse = 0
        var inFlightReuse = 0
        var reapRequests = 0
        var candidatePIDs = 0
        var signalsSent = 0
        var rejectedReusedPIDs = 0
        var captureDurationTotalMilliseconds = 0.0
        var captureDurationMaximumMilliseconds = 0.0

        init(epoch: UInt64 = 0, activeCaptureCount: Int = 0) {
            self.epoch = epoch
            self.activeCaptureCount = activeCaptureCount
            self.maximumCaptureInFlight = activeCaptureCount
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func captureStarted(
        at startedAtNanoseconds: UInt64
    ) -> RemoteOrphanProcessCaptureMetricToken {
        state.withLock { state in
            state.activeCaptureCount += 1
            state.captureStarted += 1
            state.maximumCaptureInFlight = max(
                state.maximumCaptureInFlight,
                state.activeCaptureCount
            )
            return RemoteOrphanProcessCaptureMetricToken(
                epoch: state.epoch,
                startedAtNanoseconds: startedAtNanoseconds
            )
        }
    }

    func captureCompleted(
        _ token: RemoteOrphanProcessCaptureMetricToken,
        at completedAtNanoseconds: UInt64,
        processCount: Int
    ) {
        state.withLock { state in
            state.activeCaptureCount = max(0, state.activeCaptureCount - 1)
            guard state.epoch == token.epoch else { return }
            let elapsedNanoseconds = completedAtNanoseconds >= token.startedAtNanoseconds
                ? completedAtNanoseconds - token.startedAtNanoseconds
                : 0
            let durationMilliseconds = Double(elapsedNanoseconds) / 1_000_000
            state.captureCompleted += 1
            state.capturedProcessCount += processCount
            state.captureDurationTotalMilliseconds += durationMilliseconds
            state.captureDurationMaximumMilliseconds = max(
                state.captureDurationMaximumMilliseconds,
                durationMilliseconds
            )
        }
    }

    func recordCacheReuse(_ token: RemoteOrphanProcessCaptureMetricToken) {
        state.withLock { state in
            guard state.epoch == token.epoch else { return }
            state.cacheReuse += 1
        }
    }

    func recordInFlightReuse(_ token: RemoteOrphanProcessCaptureMetricToken) {
        state.withLock { state in
            guard state.epoch == token.epoch else { return }
            state.inFlightReuse += 1
        }
    }

    func reapStarted() -> RemoteOrphanProcessReapMetricToken {
        state.withLock { state in
            state.reapRequests += 1
            return RemoteOrphanProcessReapMetricToken(epoch: state.epoch)
        }
    }

    func reapCompleted(
        _ token: RemoteOrphanProcessReapMetricToken,
        candidatePIDs: Int,
        signalsSent: Int,
        rejectedReusedPIDs: Int
    ) {
        state.withLock { state in
            guard state.epoch == token.epoch else { return }
            state.candidatePIDs += candidatePIDs
            state.signalsSent += signalsSent
            state.rejectedReusedPIDs += rejectedReusedPIDs
        }
    }

    func snapshot() -> RemoteOrphanProcessSnapshotMetrics {
        state.withLock { state in
            RemoteOrphanProcessSnapshotMetrics(
                captureStarted: state.captureStarted,
                captureCompleted: state.captureCompleted,
                captureInFlight: state.activeCaptureCount,
                maximumCaptureInFlight: state.maximumCaptureInFlight,
                capturedProcessCount: state.capturedProcessCount,
                cacheReuse: state.cacheReuse,
                inFlightReuse: state.inFlightReuse,
                reapRequests: state.reapRequests,
                candidatePIDs: state.candidatePIDs,
                signalsSent: state.signalsSent,
                rejectedReusedPIDs: state.rejectedReusedPIDs,
                captureDurationTotalMilliseconds: state.captureDurationTotalMilliseconds,
                captureDurationMaximumMilliseconds: state.captureDurationMaximumMilliseconds,
                processLaunches: 0
            )
        }
    }

    func reset() {
        state.withLock { state in
            state = State(
                epoch: state.epoch &+ 1,
                activeCaptureCount: state.activeCaptureCount
            )
        }
    }
}
