import Foundation

/// Owns the boundary between SwiftUI/AppKit callbacks and terminal portal mutations.
///
/// `NSViewRepresentable.updateNSView`, `NSView.layout`, and move-to-window callbacks
/// can run while SwiftUI or AppKit is already resolving the hosting hierarchy. Portal
/// binding reparents and resizes the real terminal view, so doing it from those
/// callbacks can synchronously re-enter `NSHostingView` layout on macOS 15.
///
/// Each representable coordinator owns one scheduler. Repeated callbacks retain the
/// latest reconciliation closure while accumulating required work, then flush after
/// the originating framework callback has returned.
@MainActor
final class TerminalPortalReconciliationScheduler {
    private enum Phase { case idle, scheduled, applying }
    private var pendingRequest = TerminalPortalReconciliationRequest(reasons: [])
    private var pendingReconciliation: (@MainActor (TerminalPortalReconciliationRequest) -> Void)?
    private var phase = Phase.idle

    func stage(
        reasons: TerminalPortalReconciliationReasons = [],
        reconciliation: @escaping @MainActor (TerminalPortalReconciliationRequest) -> Void
    ) {
        pendingRequest.reasons.formUnion(reasons)
        pendingReconciliation = reconciliation
        scheduleFlushIfNeeded()
    }

    func cancel() {
        pendingRequest = TerminalPortalReconciliationRequest(reasons: [])
        pendingReconciliation = nil
    }

    private func scheduleFlushIfNeeded() {
        guard phase == .idle else { return }
        phase = .scheduled
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but Foundation does not
            // annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self?.flushPendingReconciliation()
            }
        }
    }

    /// Flushes the staged reconciliation at a caller-owned safe boundary.
    func flushPendingReconciliation() {
        // AppKit can drain a nested run loop while the current reconciliation
        // lays out or reparents views. That delivery must leave pending work
        // with this owner until the active geometry pass has unwound.
        guard phase != .applying else { return }
        let request = pendingRequest
        let reconciliation = pendingReconciliation
        pendingRequest = TerminalPortalReconciliationRequest(reasons: [])
        pendingReconciliation = nil
        phase = .applying
        defer {
            phase = .idle
            if pendingReconciliation != nil { scheduleFlushIfNeeded() }
        }
        reconciliation?(request)
    }
}

