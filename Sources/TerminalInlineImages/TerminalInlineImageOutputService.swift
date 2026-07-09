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
    private let outputDemand = RenderDemandCounter()
    // SAFETY: Ghostty's synchronous PTY callback cannot await an actor. This lock protects
    // only a bounded set of surface ids; its hot critical section is one demand recheck and insert.
    private let pendingSurfaceLock = NSLock()
    // SAFETY: every access is guarded by `pendingSurfaceLock`.
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
    func retainNotifications() -> @Sendable () -> Void {
        let tickRetention = retainTickDemand()
        let outputRetention = outputDemand.retain()
        return { [weak self] in
            outputRetention.release()
            tickRetention.release()
            self?.discardPendingSurfacesIfInactive()
        }
    }

    /// Records output from Ghostty's synchronous pre-parser PTY callback.
    nonisolated func noteSurfaceOutput(surfaceID: UUID) {
        guard outputDemand.isActive else { return }
        pendingSurfaceLock.lock()
        guard outputDemand.isActive else {
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
        let surfaceIDs = pendingSurfaceIDs
        pendingSurfaceIDs.removeAll()
        pendingSurfaceLock.unlock()
        for surfaceID in surfaceIDs {
            notificationCenter.post(name: notificationName(for: surfaceID), object: nil)
        }
    }

    private func discardPendingSurfacesIfInactive() {
        pendingSurfaceLock.lock()
        if !outputDemand.isActive {
            pendingSurfaceIDs.removeAll()
        }
        pendingSurfaceLock.unlock()
    }
}
