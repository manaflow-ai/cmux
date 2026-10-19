import Foundation

/// Owns the boundary between SwiftUI/AppKit callbacks and table mutations.
///
/// `NSViewRepresentable.updateNSView` and scroll-view bounds notifications can
/// be delivered while SwiftUI or AppKit is already resolving layout. Mutating
/// `NSTableView` from those callbacks can synchronously re-enter the same
/// layout transaction. This scheduler keeps the latest table input, coalesced
/// reload/viewport signals, and ordered post-update actions, then flushes them
/// after the originating callback has returned.
@MainActor
final class SidebarWorkspaceTableMutationScheduler {
    private var pendingApply: SidebarWorkspaceTableApplyInput?
    private var shouldFlushViewportChange = false
    private var shouldFlushTableReload = false
    private var shouldFlushContentRefresh = false
    private var pendingRowHeightChanges: Set<SidebarWorkspaceRenderItemID> = []
    private var pendingPostUpdateActions: [@MainActor () -> Void] = []
    private var isFlushScheduled = false
    private var isFlushing = false
    private let applyFlush: @MainActor (SidebarWorkspaceTableApplyInput) -> Void
    private let viewportChangeFlush: @MainActor () -> Void
    private let reloadFlush: @MainActor () -> Void
    private let contentRefreshFlush: @MainActor () -> Void
    private let rowHeightFlush: @MainActor (Set<SidebarWorkspaceRenderItemID>) -> Void

    init(
        applyFlush: @escaping @MainActor (SidebarWorkspaceTableApplyInput) -> Void,
        viewportChangeFlush: @escaping @MainActor () -> Void,
        reloadFlush: @escaping @MainActor () -> Void,
        contentRefreshFlush: @escaping @MainActor () -> Void = {},
        rowHeightFlush: @escaping @MainActor (Set<SidebarWorkspaceRenderItemID>) -> Void = { _ in }
    ) {
        self.applyFlush = applyFlush
        self.viewportChangeFlush = viewportChangeFlush
        self.reloadFlush = reloadFlush
        self.contentRefreshFlush = contentRefreshFlush
        self.rowHeightFlush = rowHeightFlush
    }

    func stageApply(_ input: SidebarWorkspaceTableApplyInput) {
        pendingApply = input
        scheduleFlushIfNeeded()
    }

    func stageViewportChange() {
        shouldFlushViewportChange = true
        scheduleFlushIfNeeded()
    }

    func cancelPendingApplyAndViewport() {
        pendingApply = nil
        shouldFlushViewportChange = false
        shouldFlushContentRefresh = false
    }

    func stageTableReload() {
        shouldFlushTableReload = true
        scheduleFlushIfNeeded()
    }

    /// Coalesces unread-driven row content behind the authoritative table apply.
    /// AppKit cells must not be reconfigured while a staged row graph is being
    /// reloaded or reordered.
    func stageContentRefresh() {
        shouldFlushContentRefresh = true
        scheduleFlushIfNeeded()
    }

    /// Coalesces row-height changes by stable identity and applies them only
    /// after the originating AppKit callback has returned.
    func stageRowHeightChange(_ rowId: SidebarWorkspaceRenderItemID) {
        pendingRowHeightChanges.insert(rowId)
        scheduleFlushIfNeeded()
    }

    func stagePostUpdateActions(_ actions: [@MainActor () -> Void]) {
        guard !actions.isEmpty else { return }
        pendingPostUpdateActions.append(contentsOf: actions)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled, !isFlushing else { return }
        isFlushScheduled = true
        // Deliberately retain the scheduler through this turn. Post-update
        // actions can commit user edits while their controller is tearing down.
        RunLoop.main.perform(inModes: [.common]) {
            // RunLoop guarantees main-thread delivery, but Foundation does
            // not annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self.flushPendingMutations()
            }
        }
    }

    private func flushPendingMutations() {
        let apply = pendingApply
        let flushViewportChange = shouldFlushViewportChange
        let flushTableReload = shouldFlushTableReload
        let flushContentRefresh = shouldFlushContentRefresh
        let rowHeightChanges = pendingRowHeightChanges
        let postUpdateActions = pendingPostUpdateActions
        pendingApply = nil
        shouldFlushViewportChange = false
        shouldFlushTableReload = false
        shouldFlushContentRefresh = false
        pendingRowHeightChanges.removeAll(keepingCapacity: true)
        pendingPostUpdateActions.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        isFlushing = true
        defer {
            isFlushing = false
            if pendingMutationsExist {
                scheduleFlushIfNeeded()
            }
        }

        // Resolve precedence only from this atomic snapshot. A surviving apply
        // owns the row graph; if it was canceled before flush, the queued
        // reload remains the synchronization fallback.
        if flushTableReload, apply == nil {
            reloadFlush()
        }
        if let apply {
            applyFlush(apply)
        }
        if flushContentRefresh {
            contentRefreshFlush()
        }
        if !rowHeightChanges.isEmpty {
            rowHeightFlush(rowHeightChanges)
        }
        if flushViewportChange {
            viewportChangeFlush()
        }
        for action in postUpdateActions {
            action()
        }
    }

    private var pendingMutationsExist: Bool {
        pendingApply != nil
            || shouldFlushViewportChange
            || shouldFlushTableReload
            || shouldFlushContentRefresh
            || !pendingRowHeightChanges.isEmpty
            || !pendingPostUpdateActions.isEmpty
    }
}
