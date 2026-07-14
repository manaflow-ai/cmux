import CmuxTerminal
import CmuxTerminalCore
import Foundation
import os

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
    /// Hot-path gate checked on every PTY read for every surface. One unfair-lock
    /// word keeps the no-demand case (inline thumbnails off, or no visible surface
    /// retaining output) free of NSLock acquisition and dictionary/UUID hashing.
    private let activeRetentionCount = OSAllocatedUnfairLock(initialState: 0)
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
        activeRetentionCount.withLock { $0 += 1 }
        let tickRetention = retainTickDemand()
        let didRelease = OSAllocatedUnfairLock(initialState: false)
        return { [weak self] in
            let alreadyReleased = didRelease.withLock { released in
                let previous = released
                released = true
                return previous
            }
            guard !alreadyReleased else { return }
            self?.activeRetentionCount.withLock { $0 = max(0, $0 - 1) }
            surfaceRetention.release()
            tickRetention.release()
            self?.releaseSurfaceIfInactive(surfaceID: surfaceID, demand: surfaceDemand)
        }
    }

    /// Records output from Ghostty's synchronous pre-parser PTY callback.
    nonisolated func noteSurfaceOutput(surfaceID: UUID) {
        guard activeRetentionCount.withLock({ $0 > 0 }) else { return }
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
