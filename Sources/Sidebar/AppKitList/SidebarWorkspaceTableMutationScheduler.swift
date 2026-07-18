import Foundation

/// Coalesces representable and viewport inputs until their callbacks return.
///
/// AppKit exposes no completion signal for `updateNSView` or bounds-change
/// delivery. A main-run-loop turn is the deterministic callback boundary: it
/// prevents table mutation from reentering the active SwiftUI/AppKit layout
/// transaction without relying on elapsed time.
@MainActor
final class SidebarWorkspaceTableMutationScheduler {
    private var pendingApply: SidebarWorkspaceTableApplyInput?
    private var shouldFlushViewportChange = false
    private var isFlushScheduled = false
    private let applyFlush: @MainActor (SidebarWorkspaceTableApplyInput) -> Void
    private let viewportChangeFlush: @MainActor () -> Void

    init(
        applyFlush: @escaping @MainActor (SidebarWorkspaceTableApplyInput) -> Void,
        viewportChangeFlush: @escaping @MainActor () -> Void
    ) {
        self.applyFlush = applyFlush
        self.viewportChangeFlush = viewportChangeFlush
    }

    func stageApply(_ input: SidebarWorkspaceTableApplyInput) {
        pendingApply = input
        scheduleFlushIfNeeded()
    }

    func stageViewportChange() {
        shouldFlushViewportChange = true
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but its closure is not
            // annotated with MainActor in Foundation.
            MainActor.assumeIsolated {
                self?.flushPendingMutations()
            }
        }
    }

    private func flushPendingMutations() {
        let apply = pendingApply
        let flushViewportChange = shouldFlushViewportChange
        pendingApply = nil
        shouldFlushViewportChange = false
        isFlushScheduled = false

        if let apply {
            applyFlush(apply)
        }
        if flushViewportChange {
            viewportChangeFlush()
        }
    }
}
