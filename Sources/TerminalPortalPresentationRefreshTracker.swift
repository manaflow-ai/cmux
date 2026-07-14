import AppKit

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
    @MainActor
    func runBulkSynchronization<Entry>(
        prepare: () -> Void,
        entries: () -> [Entry],
        synchronize: (Entry) -> Void
    ) {
        prepare()
        entries().forEach(synchronize)
    }

    func retireAndDetachHostedView(withId hostedId: ObjectIdentifier, reason: String) {
        if let entry = entriesByHostedId[hostedId], let hostedView = entry.hostedView {
            hostedView.retirePortalHostIfOwned(ownerHostId: entry.anchorHostId, reason: reason)
        }
        detachHostedView(withId: hostedId)
    }

    /// Updates portal stacking state without changing whether the entry is visible.
    func updateEntryPriority(forHostedId hostedId: ObjectIdentifier, zPriority: Int) {
        guard var entry = entriesByHostedId[hostedId], entry.zPriority != zPriority else { return }
        entry.zPriority = zPriority
        entriesByHostedId[hostedId] = entry
    }

    /// Preserves a detached anchor only while one authoritative replacement is in flight.
    func prepareEntryForTransientReattach(
        forHostedId hostedId: ObjectIdentifier,
        ownershipGeneration: UInt64
    ) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        transientRecoveryExpiryTasksByHostedId.removeValue(forKey: hostedId)?.cancel()
        entry.transientAnchorRecoveryGeneration = ownershipGeneration
        entriesByHostedId[hostedId] = entry
        reconcileTransientRecoveryExpiry(forHostedId: hostedId)
    }

    func updateTransientReattachCandidate(
        forHostedId hostedId: ObjectIdentifier,
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64,
        registrationToken: UInt64 = 0,
        isUsable: Bool
    ) {
        let wasUsableCandidate = transientReattachCandidatesByHostedId[hostedId]?[hostId]?.isUsable == true
        transientReattachCandidatesByHostedId[hostedId, default: [:]][hostId] = TransientPortalHostCandidate(
            ownershipGeneration: ownershipGeneration,
            registrationToken: registrationToken,
            isUsable: isUsable
        )

        guard let entry = entriesByHostedId[hostedId],
              let recoveryGeneration = entry.transientAnchorRecoveryGeneration else { return }
        if ownershipGeneration > recoveryGeneration {
            clearTransientAnchorRecovery(forHostedId: hostedId, clearCandidates: false)
            pruneDeadEntries()
            return
        }
        let hasUsableCandidate = transientReattachCandidatesByHostedId[hostedId]?.values.contains {
            $0.ownershipGeneration == recoveryGeneration && $0.isUsable
        } == true
        if hasUsableCandidate {
            transientRecoveryExpiryTasksByHostedId.removeValue(forKey: hostedId)?.cancel()
        } else if wasUsableCandidate {
            // Geometry can pass through a tiny placeholder before the queued
            // mutation commits. Its drain watcher owns cancellation so this
            // callback cannot prune a still-settling replacement early.
            return
        } else {
            reconcileTransientRecoveryExpiry(forHostedId: hostedId)
        }
    }

    func unregisterTransientReattachCandidate(
        forHostedId hostedId: ObjectIdentifier,
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64? = nil,
        registrationToken: UInt64? = nil
    ) {
        if ownershipGeneration != nil || registrationToken != nil {
            guard let registeredCandidate = transientReattachCandidatesByHostedId[hostedId]?[hostId]
            else { return }
            if let ownershipGeneration,
               registeredCandidate.ownershipGeneration != ownershipGeneration { return }
            if let registrationToken,
               registeredCandidate.registrationToken != registrationToken { return }
        }
        transientReattachCandidatesByHostedId[hostedId]?.removeValue(forKey: hostId)
        if transientReattachCandidatesByHostedId[hostedId]?.isEmpty == true {
            transientReattachCandidatesByHostedId.removeValue(forKey: hostedId)
        }
        guard let recoveryGeneration = entriesByHostedId[hostedId]?.transientAnchorRecoveryGeneration else {
            return
        }
        if let ownershipGeneration, recoveryGeneration != ownershipGeneration {
            return
        }
        let hasUsableCandidate = transientReattachCandidatesByHostedId[hostedId]?.values.contains {
            $0.ownershipGeneration == recoveryGeneration && $0.isUsable
        } == true
        guard !hasUsableCandidate else { return }
        clearTransientAnchorRecovery(forHostedId: hostedId, clearCandidates: false)
        pruneDeadEntries()
    }

    func clearTransientAnchorRecovery(
        forHostedId hostedId: ObjectIdentifier,
        clearCandidates: Bool
    ) {
        transientRecoveryExpiryTasksByHostedId.removeValue(forKey: hostedId)?.cancel()
        if clearCandidates {
            transientReattachCandidatesByHostedId.removeValue(forKey: hostedId)
        }
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.transientAnchorRecoveryGeneration = nil
        entriesByHostedId[hostedId] = entry
    }

    func transientAnchorRecoveryIsAuthoritative(_ entry: Entry) -> Bool {
        guard let ownershipGeneration = entry.transientAnchorRecoveryGeneration,
              let terminalSurface = entry.hostedView?.surfaceView.terminalSurface else { return false }
        return terminalSurface.isPortalHostReplacementPending(
            ownershipGeneration: ownershipGeneration
        )
    }

    private func reconcileTransientRecoveryExpiry(forHostedId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId[hostedId],
              let recoveryGeneration = entry.transientAnchorRecoveryGeneration else { return }
        let hasUsableCandidate = transientReattachCandidatesByHostedId[hostedId]?.values.contains {
            $0.ownershipGeneration == recoveryGeneration && $0.isUsable
        } == true
        if hasUsableCandidate {
            transientRecoveryExpiryTasksByHostedId.removeValue(forKey: hostedId)?.cancel()
            return
        }
        guard transientRecoveryExpiryTasksByHostedId[hostedId] == nil else { return }

        transientRecoveryExpiryTasksByHostedId[hostedId] = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self,
                  entriesByHostedId[hostedId]?.transientAnchorRecoveryGeneration == recoveryGeneration else {
                return
            }
            transientRecoveryExpiryTasksByHostedId.removeValue(forKey: hostedId)
            clearTransientAnchorRecovery(forHostedId: hostedId, clearCandidates: false)
            pruneDeadEntries()
        }
    }

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

    func synchronizeHostedViewForAnchor(
        _ anchorView: NSView,
        syncLayout: Bool = true
    ) {
        // A no-layout synchronization runs from representable/AppKit callbacks.
        // It may update geometry, but forcing display there would re-enter the
        // view update that requested it. Keep this callback scoped to its anchor;
        // the queued portal-owned pass coalesces reconciliation for all entries.
        let allowPresentationRefresh = syncLayout
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]

        let interactive = hostView.inLiveResize
            || window?.inLiveResize == true
            || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
        guard interactive else {
            pruneDeadEntries()
            if let primaryHostedId {
                synchronizeHostedView(
                    withId: primaryHostedId,
                    syncLayout: false,
                    allowPresentationRefresh: false
                )
            }
            scheduleExternalGeometrySynchronize(forceImmediate: false)
            return
        }

        guard ensureInstalled(syncLayout: false) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        if let primaryHostedId {
            synchronizeHostedView(
                withId: primaryHostedId,
                syncLayout: false,
                allowPresentationRefresh: allowPresentationRefresh
            )
        }
        synchronizeAllHostedViews(
            excluding: primaryHostedId,
            syncLayout: false,
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

    @discardableResult
    func scheduleDeferredFullSynchronizeAll() -> Task<Void, Never> {
        fullSynchronizationScheduler.schedule { [weak self] in
            guard let self else { return }
            synchronizeAllHostedViews(excluding: nil)
        }
    }

    func synchronizeAllHostedViews(
        excluding hostedIdToSkip: ObjectIdentifier?,
        syncLayout: Bool = true,
        allowPresentationRefresh: Bool = true
    ) {
        guard ensureInstalled(syncLayout: false) else { return }
        runBulkSynchronization(
            prepare: {
                if syncLayout {
                    synchronizeLayoutHierarchy()
                } else {
                    _ = synchronizeHostFrameToReference()
                }
                pruneDeadEntries()
            },
            entries: {
                Array(entriesByHostedId.keys).filter { $0 != hostedIdToSkip }
            },
            synchronize: { hostedId in
                synchronizeHostedView(
                    withId: hostedId,
                    syncLayout: false,
                    allowPresentationRefresh: allowPresentationRefresh
                )
            }
        )
    }
}

extension TerminalWindowPortalRegistry {
    static func hideHostedView(_ hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        mappedPortal(for: hostedView)?.hideEntry(forHostedId: hostedId)
    }

    /// Update visibleInUI on an existing portal entry without rebinding.
    @discardableResult
    static func updateEntryVisibility(
        for hostedView: GhosttySurfaceScrollView,
        visibleInUI: Bool
    ) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let portal = mappedPortal(for: hostedView) else { return visibleInUI }
        return portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    /// Updates portal stacking state without changing whether the entry is visible.
    static func updateEntryPriority(for hostedView: GhosttySurfaceScrollView, zPriority: Int) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let portal = mappedPortal(for: hostedView) else { return }
        portal.updateEntryPriority(forHostedId: hostedId, zPriority: zPriority)
    }

    static func prepareForTransientReattach(
        hostedView: GhosttySurfaceScrollView,
        ownershipGeneration: UInt64
    ) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let portal = mappedPortal(for: hostedView) else { return }
        portal.prepareEntryForTransientReattach(
            forHostedId: hostedId,
            ownershipGeneration: ownershipGeneration
        )
    }

    static func updateTransientReattachCandidate(
        hostedView: GhosttySurfaceScrollView,
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64,
        registrationToken: UInt64 = 0,
        isUsable: Bool
    ) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let portal = mappedPortal(for: hostedView) else { return }
        portal.updateTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: hostId,
            ownershipGeneration: ownershipGeneration,
            registrationToken: registrationToken,
            isUsable: isUsable
        )
    }

    static func unregisterTransientReattachCandidate(
        hostedView: GhosttySurfaceScrollView,
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64? = nil,
        registrationToken: UInt64? = nil
    ) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let portal = mappedPortal(for: hostedView) else { return }
        portal.unregisterTransientReattachCandidate(
            forHostedId: hostedId,
            hostId: hostId,
            ownershipGeneration: ownershipGeneration,
            registrationToken: registrationToken
        )
    }
}
