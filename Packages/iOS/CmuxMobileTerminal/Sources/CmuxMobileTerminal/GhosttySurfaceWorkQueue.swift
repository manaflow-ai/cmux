import Foundation

/// Owns the serial libghostty work queue for one surface generation.
/// All mutable state is accessed only from `queue`; main-actor code replaces whole instances on recovery.
final class GhosttySurfaceWorkQueue: @unchecked Sendable {
    let queue: DispatchQueue
    /// Accessed only from ``queue`` while refreshing the recovery snapshot cache.
    var lastRecoverySnapshotTime: CFTimeInterval = 0
    #if DEBUG
    /// Accessed only from ``queue`` while producing DEBUG accessibility snapshots.
    var lastAccessibilityTextTime: CFTimeInterval = 0
    #endif

    init(generation: UInt64) {
        // carve-out justification: serial event-delivery queue for low-level libghostty C calls; not used as a lock.
        queue = DispatchQueue(
            label: "dev.cmux.GhosttySurfaceView.output.\(generation)",
            qos: .userInitiated
        )
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
