import AppKit

extension GhosttyTerminalView {
    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // A replaced host cannot mutate state while the hosted view is attached elsewhere.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }
}

@MainActor
final class TerminalPortalMutationScheduler {
    private typealias Mutation = @MainActor () -> Void

    private var cancellationGeneration: UInt64 = 0
    private var pendingMutation: Mutation?
    private var drainTask: Task<Void, Never>?

    @discardableResult
    func schedule(_ mutation: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        pendingMutation = mutation
        if let drainTask {
            return drainTask
        }

        let scheduledCancellationGeneration = cancellationGeneration

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.cancellationGeneration == scheduledCancellationGeneration {
                // Leave the SwiftUI/AppKit callback stack before every commit.
                // Schedules during the yield replace one pending snapshot instead
                // of canceling and multiplying tasks under layout churn.
                await Task.yield()
                guard !Task.isCancelled,
                      self.cancellationGeneration == scheduledCancellationGeneration,
                      let mutation = self.pendingMutation else { break }
                self.pendingMutation = nil
                mutation()
            }

            guard self.cancellationGeneration == scheduledCancellationGeneration else { return }
            self.drainTask = nil
        }
        drainTask = task
        return task
    }

    func cancel() {
        cancellationGeneration &+= 1
        pendingMutation = nil
        drainTask?.cancel()
        drainTask = nil
    }
}

enum TerminalPortalVisibilityRefreshPolicy {
    case immediate
    case deferredToPortal

    @MainActor
    func refresh(hostedView: GhosttySurfaceScrollView) {
        switch self {
        case .immediate:
            hostedView.refreshSurfaceNow(reason: "setVisibleInUI")
        case .deferredToPortal:
            break
        }
    }
}

extension GhosttySurfaceScrollView {
    func setVisibleInUI(_ visible: Bool) {
        setVisibleInUI(visible, refreshPolicy: .immediate)
    }
}

struct TerminalPortalPresentationRefreshTracker {
    private var generation: UInt64 = 0
    private var pendingByHostedId: [ObjectIdentifier: UInt64] = [:]

    mutating func request(for hostedId: ObjectIdentifier) {
        generation &+= 1
        pendingByHostedId[hostedId] = generation
    }

    mutating func cancel(for hostedId: ObjectIdentifier) {
        pendingByHostedId.removeValue(forKey: hostedId)
    }

    func pendingGeneration(for hostedId: ObjectIdentifier) -> UInt64? {
        pendingByHostedId[hostedId]
    }

    mutating func complete(for hostedId: ObjectIdentifier, generation: UInt64) {
        guard pendingByHostedId[hostedId] == generation else { return }
        pendingByHostedId.removeValue(forKey: hostedId)
    }
}

extension WindowTerminalPortal {
    func requestPresentationRefresh(forHostedId hostedId: ObjectIdentifier) {
        presentationRefreshTracker.request(for: hostedId)
    }

    func refreshPresentation(
        forHostedId hostedId: ObjectIdentifier,
        hostedView: GhosttySurfaceScrollView,
        reason: String,
        allowPresentationRefresh: Bool
    ) -> Bool {
        guard allowPresentationRefresh else {
            requestPresentationRefresh(forHostedId: hostedId)
            return false
        }
        let generation = presentationRefreshTracker.pendingGeneration(for: hostedId)
        hostedView.refreshSurfaceNow(reason: reason)
        if let generation {
            presentationRefreshTracker.complete(for: hostedId, generation: generation)
        }
        return true
    }

    func refreshPendingPresentationIfReady(
        forHostedId hostedId: ObjectIdentifier,
        hostedView: GhosttySurfaceScrollView,
        isReady: Bool,
        allowPresentationRefresh: Bool
    ) {
        guard isReady,
              allowPresentationRefresh,
              presentationRefreshTracker.pendingGeneration(for: hostedId) != nil else { return }
        hostedView.reconcileGeometryNow()
        _ = refreshPresentation(
            forHostedId: hostedId,
            hostedView: hostedView,
            reason: "portal.presentation",
            allowPresentationRefresh: true
        )
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView, syncLayout: Bool = true) {
        // A no-layout synchronization runs from representable/AppKit callbacks.
        // It may update geometry, but forcing display there would re-enter the
        // view update that requested it. The queued full sync owns presentation.
        let allowPresentationRefresh = syncLayout
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(
                withId: primaryHostedId,
                syncLayout: syncLayout,
                allowPresentationRefresh: allowPresentationRefresh
            )
        }

        // One anchor can miss a geometry callback during structural churn.
        synchronizeAllHostedViews(
            excluding: primaryHostedId,
            syncLayout: syncLayout,
            allowPresentationRefresh: allowPresentationRefresh
        )
        reconcileVisibleHostedViewsAfterGeometrySync(
            reason: "portal.anchorGeometrySync",
            allowPresentationRefresh: allowPresentationRefresh
        )
        scheduleDeferredFullSynchronizeAll()
    }

    func reconcileVisibleHostedViewsAfterGeometrySync(
        reason: String,
        allowPresentationRefresh: Bool = true
    ) {
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            guard let entry = entriesByHostedId[hostedId],
                  entry.visibleInUI,
                  let hostedView = entry.hostedView,
                  !hostedView.isHidden,
                  hostedView.reconcileGeometryNow() else { continue }
            _ = refreshPresentation(
                forHostedId: hostedId,
                hostedView: hostedView,
                reason: reason,
                allowPresentationRefresh: allowPresentationRefresh
            )
        }
    }

    func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.synchronizeAllHostedViews(excluding: nil)
        }
    }

    func synchronizeAllHostedViews(
        excluding hostedIdToSkip: ObjectIdentifier?,
        syncLayout: Bool = true,
        allowPresentationRefresh: Bool = true
    ) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds where hostedId != hostedIdToSkip {
            synchronizeHostedView(
                withId: hostedId,
                syncLayout: syncLayout,
                allowPresentationRefresh: allowPresentationRefresh
            )
        }
    }
}
