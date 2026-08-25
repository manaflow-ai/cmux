import Foundation

/// Actor-owned coalescing state for ``GhosttyPointerStyleIngress``.
struct GhosttyPointerStyleIngressPendingState: Sendable {
    /// The bounded pointer callbacks pending for one runtime lifetime.
    struct RuntimePending: Sendable {
        var firstShape: GhosttyPointerStyleIngressRequest?
        var latestShape: GhosttyPointerStyleIngressRequest?
        var latestLinkHover: GhosttyPointerStyleIngressRequest?
        var latestRuntimeReset: GhosttyPointerStyleIngressRequest?
        var latestRuntimeEnded: GhosttyPointerStyleIngressRequest?
    }

    var activeRuntimeLifetimeId: UUID?
    var retiredRuntimeLifetimeIds: Set<UUID> = []
    var byRuntime: [UUID: RuntimePending] = [:]
    var nextSequence: UInt64 = 0
    var drainScheduled = false
}
