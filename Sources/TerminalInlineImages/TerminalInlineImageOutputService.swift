import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Bridges Ghostty's pre-parser PTY tee to post-parser, per-surface output notifications.
///
/// The PTY callback is synchronous and cannot await an actor. A small lock protects only
/// the pending surface-id set; notification delivery and all downstream work stay on main.
// SAFETY: all mutable cross-thread state is guarded by `pendingSurfaceLock`; injected
// callbacks are Sendable and the observer token is initialized once, then removed in deinit.
final class TerminalInlineImageOutputService: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let scheduleTick: @Sendable () -> Void
    private let retainTickDemand: @Sendable () -> any RenderDemandRetention
    // SAFETY: Ghostty's synchronous PTY callback cannot await an actor. This lock protects
    // only per-surface demand and a bounded set of pending ids at the C callback boundary.
    private let pendingSurfaceLock = NSLock()
    // SAFETY: every access to these properties is guarded by `pendingSurfaceLock`.
    nonisolated(unsafe) private var demandBySurfaceID: [UUID: RenderDemandCounter] = [:]
    nonisolated(unsafe) private var pendingSurfaceIDs: Set<UUID> = []
    private var tickObserver: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        scheduleTick: @escaping @Sendable () -> Void,
        retainTickDemand: @escaping @Sendable () -> any RenderDemandRetention
    ) {
        self.notificationCenter = notificationCenter
        self.scheduleTick = scheduleTick
        self.retainTickDemand = retainTickDemand
        tickObserver = notificationCenter.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSurfaceNotifications()
        }
    }

    deinit {
        if let tickObserver {
            notificationCenter.removeObserver(tickObserver)
        }
    }

    /// Retains post-parser output notifications until the returned release is called.
    ///
    /// The release closure is synchronous and idempotent, so lifecycle teardown does not
    /// need an unstructured task or a main-actor hop.
    func retainNotifications(for surfaceID: UUID) -> @Sendable () -> Void {
        pendingSurfaceLock.lock()
        let surfaceDemand = demandBySurfaceID[surfaceID] ?? RenderDemandCounter()
        demandBySurfaceID[surfaceID] = surfaceDemand
        let surfaceRetention = surfaceDemand.retain()
        pendingSurfaceLock.unlock()
        let tickRetention = retainTickDemand()
        return { [weak self] in
            surfaceRetention.release()
            tickRetention.release()
            self?.releaseSurfaceIfInactive(surfaceID: surfaceID, demand: surfaceDemand)
        }
    }

    /// Records output from Ghostty's synchronous pre-parser PTY callback.
    nonisolated func noteSurfaceOutput(surfaceID: UUID) {
        pendingSurfaceLock.lock()
        guard demandBySurfaceID[surfaceID]?.isActive == true else {
            pendingSurfaceLock.unlock()
            return
        }
        pendingSurfaceIDs.insert(surfaceID)
        pendingSurfaceLock.unlock()
        scheduleTick()
    }

    nonisolated func notificationName(for surfaceID: UUID) -> Notification.Name {
        Notification.Name("cmux.terminalInlineImage.surfaceOutput.\(surfaceID.uuidString)")
    }

    private func flushPendingSurfaceNotifications() {
        pendingSurfaceLock.lock()
        let surfaceIDs = pendingSurfaceIDs.filter { demandBySurfaceID[$0]?.isActive == true }
        pendingSurfaceIDs.removeAll()
        pendingSurfaceLock.unlock()
        for surfaceID in surfaceIDs {
            notificationCenter.post(name: notificationName(for: surfaceID), object: nil)
        }
    }

    private func releaseSurfaceIfInactive(surfaceID: UUID, demand: RenderDemandCounter) {
        pendingSurfaceLock.lock()
        if demandBySurfaceID[surfaceID] === demand, !demand.isActive {
            demandBySurfaceID.removeValue(forKey: surfaceID)
            pendingSurfaceIDs.remove(surfaceID)
        }
        pendingSurfaceLock.unlock()
    }
}
