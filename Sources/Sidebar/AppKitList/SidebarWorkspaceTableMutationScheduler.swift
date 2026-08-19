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
    private var pendingHeightRowIds: Set<SidebarWorkspaceRenderItemID> = []
    private var pendingPostUpdateActions: [@MainActor () -> Void] = []
    private var isFlushScheduled = false
    private var isFlushing = false
    private let applyFlush: @MainActor (SidebarWorkspaceTableApplyInput) -> Void
    private let viewportChangeFlush: @MainActor () -> Void
    private let reloadFlush: @MainActor () -> Void
    private let contentRefreshFlush: @MainActor () -> Void
    private let heightChangeFlush: @MainActor (Set<SidebarWorkspaceRenderItemID>) -> Void

    init(
        applyFlush: @escaping @MainActor (SidebarWorkspaceTableApplyInput) -> Void,
        viewportChangeFlush: @escaping @MainActor () -> Void,
        reloadFlush: @escaping @MainActor () -> Void,
        contentRefreshFlush: @escaping @MainActor () -> Void = {},
        heightChangeFlush: @escaping @MainActor (Set<SidebarWorkspaceRenderItemID>) -> Void = { _ in }
    ) {
        self.applyFlush = applyFlush
        self.viewportChangeFlush = viewportChangeFlush
        self.reloadFlush = reloadFlush
        self.contentRefreshFlush = contentRefreshFlush
        self.heightChangeFlush = heightChangeFlush
    }

    func stageApply(_ input: SidebarWorkspaceTableApplyInput) {
        pendingApply = input
        // An authoritative apply owns the complete row graph. A separately
        // staged reload (usually from hidden-presentation pruning) would only
        // reload the old graph before this snapshot arrives, which is the
        // stale-frame ordering this boundary exists to prevent.
        shouldFlushTableReload = false
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
        pendingHeightRowIds.removeAll(keepingCapacity: true)
    }

    func stageTableReload() {
        shouldFlushTableReload = true
        scheduleFlushIfNeeded()
    }

    func stagePostUpdateActions(_ actions: [@MainActor () -> Void]) {
        guard !actions.isEmpty else { return }
        pendingPostUpdateActions.append(contentsOf: actions)
        scheduleFlushIfNeeded()
    }

    /// Coalesces a row-content refresh behind any authoritative table apply.
    /// Content publishers must not mutate cells while AppKit is moving rows.
    func stageContentRefresh() {
        shouldFlushContentRefresh = true
        scheduleFlushIfNeeded()
    }

    /// Queues height invalidation by stable row identity instead of by the
    /// transient table index. The ids are drained after structural updates.
    func stageHeightChanges(for rowIds: some Sequence<SidebarWorkspaceRenderItemID>) {
        pendingHeightRowIds.formUnion(rowIds)
        guard !pendingHeightRowIds.isEmpty else { return }
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
        let heightRowIds = pendingHeightRowIds
        let postUpdateActions = pendingPostUpdateActions
        pendingApply = nil
        shouldFlushViewportChange = false
        shouldFlushTableReload = false
        shouldFlushContentRefresh = false
        pendingHeightRowIds.removeAll(keepingCapacity: true)
        pendingPostUpdateActions.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        isFlushing = true
        defer {
            isFlushing = false
            if pendingMutationsExist {
                scheduleFlushIfNeeded()
            }
        }

        if flushTableReload, apply == nil {
            reloadFlush()
        }
        if let apply {
            applyFlush(apply)
        }
        if flushContentRefresh {
            contentRefreshFlush()
        }
        if !heightRowIds.isEmpty {
            heightChangeFlush(heightRowIds)
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
            || !pendingHeightRowIds.isEmpty
            || !pendingPostUpdateActions.isEmpty
    }
}
