import Foundation

/// Owns the boundary between SwiftUI/AppKit callbacks and table mutations.
///
/// `NSViewRepresentable.updateNSView` and scroll-view bounds notifications can
/// be delivered while SwiftUI or AppKit is already resolving layout. Mutating
/// `NSTableView` from those callbacks can synchronously re-enter the same
/// layout transaction. This scheduler keeps the latest table input, one
/// viewport signal, and ordered post-update actions, then flushes them after
/// the originating callback has returned.
@MainActor
final class SidebarWorkspaceTableMutationScheduler {
    private var pendingApply: SidebarWorkspaceTableApplyInput?
    private var shouldFlushViewportChange = false
    private var pendingPostUpdateActions: [@MainActor () -> Void] = []
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

    func cancelPendingTableMutations() {
        pendingApply = nil
        shouldFlushViewportChange = false
    }

    func stagePostUpdateActions(_ actions: [@MainActor () -> Void]) {
        guard !actions.isEmpty else { return }
        pendingPostUpdateActions.append(contentsOf: actions)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but Foundation does
            // not annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self?.flushPendingMutations()
            }
        }
    }

    private func flushPendingMutations() {
        let apply = pendingApply
        let flushViewportChange = shouldFlushViewportChange
        let postUpdateActions = pendingPostUpdateActions
        pendingApply = nil
        shouldFlushViewportChange = false
        pendingPostUpdateActions.removeAll(keepingCapacity: true)
        isFlushScheduled = false

        if let apply {
            applyFlush(apply)
        }
        if flushViewportChange {
            viewportChangeFlush()
        }
        for action in postUpdateActions {
            action()
        }
    }
}
