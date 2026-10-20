import CmuxControlSocket
import Foundation
import os

/// Once-per-episode capture gates for the socket lanes' Release telemetry.
///
/// Every timeout and rejection leaves a breadcrumb; the first one of an
/// episode also captures a warning so Sentry opens an issue with those
/// breadcrumbs attached. A completed main-actor hop, or a submission the pool
/// admits again, ends the episode.
final class SocketLaneHealth: Sendable {
    private struct Episodes: Sendable {
        var mainHopStalled = false
        var poolSaturated = false
    }

    // Lock carve-out: two booleans toggled by short compare-and-set calls from
    // nonisolated socket tasks; never held across an await.
    private let episodes = OSAllocatedUnfairLock(initialState: Episodes())

    /// Records a main-hop timeout; `true` when it starts a new stall episode.
    func recordMainHopTimeout() -> Bool {
        episodes.withLock { episodes in
            guard !episodes.mainHopStalled else { return false }
            episodes.mainHopStalled = true
            return true
        }
    }

    /// Ends the main-hop stall episode.
    func recordMainHopCompleted() {
        episodes.withLock { $0.mainHopStalled = false }
    }

    /// Records a pool rejection; `true` when it starts a new saturation episode.
    func recordPoolRejection() -> Bool {
        episodes.withLock { episodes in
            guard !episodes.poolSaturated else { return false }
            episodes.poolSaturated = true
            return true
        }
    }

    /// Ends the pool saturation episode.
    func recordPoolAdmission() {
        episodes.withLock { $0.poolSaturated = false }
    }
}

extension TerminalController {
    /// Builds the app's ``ControlOverloadResponder`` with localized copy and
    /// the Sentry breadcrumb sink.
    nonisolated static func makeSocketOverloadResponder() -> ControlOverloadResponder {
        ControlOverloadResponder(
            strings: ControlOverloadResponder.Strings(
                message: String(
                    localized: "socket.overloaded.message",
                    defaultValue: "cmux is handling too many control-socket requests right now, so this one was not run. Retry in a moment."
                )
            ),
            configuration: ControlOverloadResponder.Configuration(
                maximumConcurrentReplies: socketOverloadMaximumConcurrentReplies
            ),
            onRejection: { rejection in
                sentryBreadcrumb(
                    "socket.pool.rejection_answered",
                    category: "socket",
                    data: [
                        "reason": rejection.reason.rawValue,
                        "replied": rejection.replied,
                        "active_replies": rejection.activeReplies,
                    ]
                )
            }
        )
    }

    /// Maps the pool's drop reason onto the wire-visible rejection reason.
    nonisolated static func socketOverloadReason(
        for dropReason: ControlClientWorkerPool.DropReason
    ) -> ControlOverloadReason {
        switch dropReason {
        case .pendingQueueFull: .poolSaturated
        case .pendingExpired: .pendingExpired
        case .stopped: .serverStopping
        }
    }

    /// Hands an accepted connection the server cannot serve to the overload
    /// responder, which answers it with a structured `overloaded` error and
    /// closes it. Replaces the bare `close(2)` that every rejected client used
    /// to see as `EPIPE` (#13369).
    nonisolated func rejectSocketClient(_ socket: Int32, reason: ControlOverloadReason) {
        socketOverloadResponder.reject(socket: socket, reason: reason)
    }

    /// Records a pool rejection in Release telemetry: a breadcrumb with the
    /// pool counters on every rejection, and one captured warning per
    /// saturation episode.
    nonisolated func reportSocketPoolSaturation() async {
        let metrics = await socketClientWorkerPool.metrics()
        let data: [String: Any] = [
            "active": metrics.activeJobs,
            "pending": metrics.pendingJobs,
            "peak_active": metrics.peakActiveJobs,
            "rejected": metrics.rejectedJobs,
            "expired": metrics.expiredJobs,
            "stopped": metrics.isStopped,
        ]
        sentryBreadcrumb("socket.pool.rejected", category: "socket", data: data)
        if socketLaneHealth.recordPoolRejection() {
            sentryCaptureWarning(
                "socket.pool.saturated",
                category: "socket",
                data: data,
                contextKey: "socket_pool"
            )
        }
    }
}
