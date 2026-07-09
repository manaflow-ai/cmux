public import Foundation
import Observation
public import CmuxFoundation

/// Per-window coordinator owning the mounted-workspace set and the
/// workspace-handoff state machine that `ContentView` used to keep inline as
/// `@State` plus five private methods.
///
/// It owns the window-scoped mount/handoff state:
/// - ``mountedWorkspaceIds`` — the workspaces currently mounted (portal
///   rendering enabled), recomputed by ``reconcileMountedWorkspaceIds`` from a
///   ``WorkspaceMountPlan``. SwiftUI observes this to drive which
///   `WorkspaceContentView`s exist.
/// - ``retiringWorkspaceId`` — the previously selected workspace kept visible
///   (pinned mounted, never input-active) until the incoming workspace takes
///   focus or a 150 ms fallback fires. SwiftUI observes this for the retiring
///   workspace's render priority and re-reconciles when it changes.
/// - the private handoff generation + fallback task and the
///   ``previousSelectedWorkspaceId`` cursor that distinguishes a real selection
///   change from a re-selection.
///
/// **Per-window ownership (owner ruling 2026-06-18).** This is the per-window
/// owner of the mount/handoff slice: `ContentView` holds one instance as
/// `@State` and there is no per-window aggregate. The state is `WindowID`-keyed
/// implicitly by being one coordinator per window.
///
/// **Isolation design.** `@MainActor` because every entry point is a MainActor
/// UI path: the selection `.onChange`, the cycle-hot/pinned/retiring
/// `.onChange`/`.onReceive` closures, the SwiftUI `body`-feeding reads, and the
/// fallback task's main-actor completion. Reads and writes go through
/// ``WorkspaceHandoffHosting`` synchronously inside one turn, preserving the
/// legacy interleavings exactly — `startWorkspaceHandoffIfNeeded` may
/// synchronously complete the handoff (fast-ready), and `completeWorkspaceHandoff`
/// synchronously disables the retiring workspace's portal rendering before
/// clearing ``retiringWorkspaceId`` so the trailing reconcile unmounts it.
/// State therefore lives on one isolation domain. `@Observable` (not
/// `ObservableObject`) so the view tracks ``mountedWorkspaceIds`` and
/// ``retiringWorkspaceId`` through Observation.
///
/// **Fallback timing.** The legacy fallback used
/// `Task.sleep(nanoseconds: 150_000_000)` and a generation guard. The
/// coordinator injects an `any Clock<Duration>` (defaulting to
/// `ContinuousClock`) and sleeps `.milliseconds(150)`; the generation guard
/// absorbs every stale fire, so no `Task.isCancelled` check is needed (the
/// sleep throws on cancel, the guard covers the post-sleep window). Tests pass
/// a manual clock.
///
/// Bodies are lifted one-for-one from `Sources/ContentView.swift`; only the
/// host-seam spellings and the DEBUG-trace hand-off changed.
@MainActor
@Observable
public final class WorkspaceHandoffCoordinator {
    /// The workspace ids currently mounted (portal rendering enabled), in
    /// priority order. Legacy `ContentView.mountedWorkspaceIds`.
    public private(set) var mountedWorkspaceIds: [UUID] = []

    /// The previously selected workspace kept visible during a handoff, or
    /// `nil` when no handoff is in flight. Legacy
    /// `ContentView.retiringWorkspaceId`.
    public private(set) var retiringWorkspaceId: UUID?

    @ObservationIgnored
    private weak var host: (any WorkspaceHandoffHosting)?

    /// The last selected workspace id observed, used to distinguish a real
    /// selection change (start a handoff) from a re-selection (clear handoff).
    /// Legacy `ContentView.previousSelectedWorkspaceId`.
    @ObservationIgnored
    private var previousSelectedWorkspaceId: UUID?

    /// Monotonic handoff generation; the fallback task captures its generation
    /// and no-ops if a newer handoff has started. Legacy
    /// `ContentView.workspaceHandoffGeneration`.
    @ObservationIgnored
    private var workspaceHandoffGeneration: UInt64 = 0

    /// The in-flight fallback task that completes the handoff after 150 ms if
    /// the incoming workspace has not taken focus. Legacy
    /// `ContentView.workspaceHandoffFallbackTask`.
    @ObservationIgnored
    private var workspaceHandoffFallbackTask: Task<Void, Never>?

    /// The clock backing the fallback delay. Injected so tests drive it
    /// deterministically; production uses `ContinuousClock`.
    @ObservationIgnored
    private let clock: any Clock<Duration>

    /// Creates a detached coordinator; call ``attach(host:)`` before use.
    ///
    /// - Parameter clock: the clock backing the handoff fallback delay.
    ///   Defaults to `ContinuousClock`.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Wires the window-side host. Held weakly: the host (the per-window
    /// `TabManager`) and the view that owns this coordinator outlive it, so a
    /// strong back-reference is unnecessary and a retain cycle would be a risk.
    public func attach(host: any WorkspaceHandoffHosting) {
        self.host = host
    }

    /// Seeds ``previousSelectedWorkspaceId`` from the current selection without
    /// starting a handoff. Legacy `ContentView`'s `.onAppear`
    /// `previousSelectedWorkspaceId = tabManager.selectedTabId`.
    public func seedPreviousSelection() {
        previousSelectedWorkspaceId = host?.selectedWorkspaceId
    }

    // MARK: - Mount reconcile

    /// Recomputes ``mountedWorkspaceIds`` from a ``WorkspaceMountPlan`` and
    /// applies portal rendering across the window's workspaces. Legacy
    /// `ContentView.reconcileMountedWorkspaceIds(tabs:selectedId:)`.
    ///
    /// - Parameters:
    ///   - orderedWorkspaceIds: overrides the host's ordered ids (the
    ///     tabs-publisher path passes the freshly delivered ids to avoid a
    ///     stale read); `nil` reads `host.orderedWorkspaceIds`.
    ///   - selectedId: overrides the host's selected id; `nil` reads
    ///     `host.selectedWorkspaceId`.
    public func reconcileMountedWorkspaceIds(
        orderedWorkspaceIds: [UUID]? = nil,
        selectedId: UUID? = nil
    ) {
        guard let host else { return }
        let orderedTabIds = orderedWorkspaceIds ?? host.orderedWorkspaceIds()
        let effectiveSelectedId = selectedId ?? host.selectedWorkspaceId
        let handoffPinnedIds = retiringWorkspaceId.map { Set([$0]) } ?? []
        let pinnedIds = handoffPinnedIds
            .union(host.mountedBackgroundWorkspaceLoadIds)
            .union(host.debugPinnedWorkspaceLoadIds)
        let isCycleHot = host.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !handoffPinnedIds.isEmpty
        let baseMaxMounted = shouldKeepHandoffPair
            ? WorkspaceMountPlan.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPlan.maxMountedWorkspaces
        let selectedCount = effectiveSelectedId == nil ? 0 : 1
        let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPlan(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedTabIds,
            isCycleHot: isCycleHot,
            maxMounted: maxMounted
        ).mountedWorkspaceIds
        let removedIds = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
        let mountedIdSet = Set(mountedWorkspaceIds)
        for workspaceId in orderedTabIds {
            host.setWorkspacePortalRenderingEnabled(
                workspaceId: workspaceId,
                enabled: mountedIdSet.contains(workspaceId),
                reason: "workspaceMount"
            )
        }
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            host.logWorkspaceHandoffEvent(
                .mountReconciled(
                    isCycleHot: isCycleHot,
                    selectedWorkspaceId: effectiveSelectedId,
                    mountedWorkspaceIds: mountedWorkspaceIds,
                    addedWorkspaceIds: added,
                    removedWorkspaceIds: removedIds
                )
            )
        }
#endif
    }

    // MARK: - Handoff state machine

    /// Begins (or skips) a workspace handoff for a new selection. Legacy
    /// `ContentView.startWorkspaceHandoffIfNeeded(newSelectedId:)`.
    public func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        guard let host else { return }
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            host.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        host.logWorkspaceHandoffEvent(
            .handoffStarted(oldSelectedWorkspaceId: oldSelectedId, newSelectedWorkspaceId: newSelectedId)
        )
#endif

        if host.workspaceIsReadyForImmediateHandoff(workspaceId: newSelectedId) {
#if DEBUG
            host.logWorkspaceHandoffEvent(.handoffFastReady(selectedWorkspaceId: newSelectedId))
#endif
            completeWorkspaceHandoff(reason: "ready")
            return
        }

        workspaceHandoffFallbackTask = Task { [generation, clock] in
            do {
                try await clock.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            await MainActor.run {
                guard self.workspaceHandoffGeneration == generation else { return }
                self.completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    /// Completes the handoff if the focused workspace is the selected one and a
    /// handoff is in flight. Legacy
    /// `ContentView.completeWorkspaceHandoffIfNeeded(focusedTabId:reason:)`.
    public func completeWorkspaceHandoffIfNeeded(focusedWorkspaceId: UUID, reason: String) {
        guard let host else { return }
        guard focusedWorkspaceId == host.selectedWorkspaceId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    /// Completes the handoff: cancels the fallback, disables the retiring
    /// workspace's portal rendering, clears ``retiringWorkspaceId``, and flushes
    /// the deferred previous-workspace unfocus. Legacy
    /// `ContentView.completeWorkspaceHandoff(reason:)`.
    public func completeWorkspaceHandoff(reason: String) {
        guard let host else { return }
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Disable portal rendering for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Disabling here also cancels stale layout follow-up
        // loops that could re-show an old terminal above the newly selected workspace.
        if let retiring {
            host.setWorkspacePortalRenderingEnabled(
                workspaceId: retiring,
                enabled: false,
                reason: "workspaceHandoff"
            )
        }

        retiringWorkspaceId = nil
        host.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        host.logWorkspaceHandoffEvent(.handoffCompleted(reason: reason, retiringWorkspaceId: retiring))
#endif
    }

    // MARK: - Workspace removal reconciliation

    /// Drops handoff/cursor state for workspaces that no longer exist. Driven by
    /// `ContentView`'s workspace-list change handler (now `@Observable`
    /// observation of `workspaces.tabs`, formerly a `tabsPublisher` `.onReceive`):
    /// the `retiringWorkspaceId`/`previousSelectedWorkspaceId` prune that runs
    /// before `reconcileMountedWorkspaceIds(tabs:)`.
    ///
    /// - Parameter existingWorkspaceIds: the ids of the workspaces that still
    ///   exist.
    public func pruneRemovedWorkspaces(existingWorkspaceIds: Set<UUID>) {
        if let retiringWorkspaceId, !existingWorkspaceIds.contains(retiringWorkspaceId) {
            self.retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
        }
        if let previousSelectedWorkspaceId, !existingWorkspaceIds.contains(previousSelectedWorkspaceId) {
            self.previousSelectedWorkspaceId = host?.selectedWorkspaceId
        }
    }
}
