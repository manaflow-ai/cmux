import CMUXMobileCore
import CmuxTerminal
import Foundation

/// Pushes terminal render events only while a mobile client is actively subscribed.
/// Ghostty notification demand is tied to subscriptions so the desktop terminal
/// path is untouched when no iPhone/iPad is attached.
@MainActor
final class MobileTerminalRenderObserver {
    static let shared = MobileTerminalRenderObserver()

    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalUpdate = false
    private var isEmitFlushScheduled = false
    private var renderGridStatesBySurfaceID: [UUID: MobileTerminalRenderGridEmissionState] = [:]
    private var demandByConnectionID: [UUID: MobileRenderGridDemandSummary] = [:]
    private let previewClock = ContinuousClock()
    private let previewUpdateInterval: Duration = .milliseconds(250)
    private var lastPreviewEmissionBySurfaceID: [UUID: ContinuousClock.Instant] = [:]
    private var pendingPreviewEmissionTasksBySurfaceID: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNotificationDemand()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let view = notification.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else {
                    return
                }
                self?.enqueueTerminalUpdate(surfaceID: surfaceID)
            }
        })
        // Frame notifications only fire when Ghostty's Metal layer pulls a
        // drawable, which it skips for surfaces whose Mac window isn't on
        // screen. Tick notifications fire on every Ghostty IO cycle (PTY wakeup,
        // action, render request), so a background workspace driven by output can
        // still push render-grid updates to the iPhone.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.enqueueTerminalUpdate(surfaceID: nil)
            }
        })
        refreshNotificationDemand()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        releaseFrameDemand?()
        releaseFrameDemand = nil
        releaseTickDemand?()
        releaseTickDemand = nil
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        isEmitFlushScheduled = false
        renderGridStatesBySurfaceID.removeAll()
        demandByConnectionID.removeAll()
        cancelAllPreviewEmissionTasks()
        MobileTerminalByteTee.shared.setRenderGridDemand(
            MobileRenderGridDemandSummary(scopes: [])
        )
    }

    func noteTerminalBytes(surfaceID: UUID) {
        guard effectiveRenderGridDemand.contains(surfaceID: surfaceID.uuidString) else { return }
        pendingSurfaceIDs.insert(surfaceID)
        // The byte tee runs before Ghostty's VT parser consumes the bytes, and
        // the hop back to the main actor can land after the current tick/frame
        // notification already fired. Schedule a fresh Ghostty tick so every
        // byte-backed pending surface gets one post-parser render-grid flush.
        GhosttyApp.shared.scheduleTick()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseFrameDemand?()
        releaseTickDemand?()
    }

    private var hasAnyRenderEventSubscribers: Bool {
        MobileHostService.hasEventSubscribers(topic: "terminal.updated") ||
            effectiveRenderGridDemand.hasDemand
    }

    private var effectiveRenderGridDemand: MobileRenderGridDemandSummary {
        let scopes = demandByConnectionID.values.map { summary -> MobileRenderGridDemandScope in
            if summary.includesLegacyAll { return .legacyAll }
            return .scoped(MobileRenderGridDemand(
                focusedSurfaceIDs: summary.focusedSurfaceIDs,
                previewSurfaceIDs: summary.previewSurfaceIDs
            ))
        }
        return MobileRenderGridDemandSummary(scopes: scopes)
    }

    func replaceConnectionDemand(
        connectionID: UUID,
        summary: MobileRenderGridDemandSummary
    ) {
        let previousConnectionDemand = demandByConnectionID[connectionID]
            ?? MobileRenderGridDemandSummary(scopes: [])
        let previousEffectiveDemand = effectiveRenderGridDemand
        if summary.hasDemand {
            demandByConnectionID[connectionID] = summary
        } else {
            demandByConnectionID.removeValue(forKey: connectionID)
        }
        let nextEffectiveDemand = effectiveRenderGridDemand
        MobileTerminalByteTee.shared.setRenderGridDemand(nextEffectiveDemand)

        let addedForConnection = summary.surfaceIDs.filter {
            !previousConnectionDemand.contains(surfaceID: $0)
        }
        if summary.includesLegacyAll && !previousConnectionDemand.includesLegacyAll {
            renderGridStatesBySurfaceID.removeAll()
            hasPendingGlobalUpdate = true
        } else {
            for surfaceIDString in addedForConnection {
                guard let surfaceID = UUID(uuidString: surfaceIDString) else { continue }
                resetEmissionState(surfaceID: surfaceID)
                pendingSurfaceIDs.insert(surfaceID)
            }
        }

        for removedID in previousEffectiveDemand.surfaceIDs.subtracting(nextEffectiveDemand.surfaceIDs) {
            guard let surfaceID = UUID(uuidString: removedID) else { continue }
            resetEmissionState(surfaceID: surfaceID)
            pendingSurfaceIDs.remove(surfaceID)
        }
        for focusedID in nextEffectiveDemand.focusedSurfaceIDs {
            guard let surfaceID = UUID(uuidString: focusedID) else { continue }
            pendingPreviewEmissionTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
            pendingSurfaceIDs.insert(surfaceID)
        }
        refreshNotificationDemand()
        if summary.hasDemand {
            enqueueTerminalUpdate(surfaceID: nil)
        }
    }

    private func refreshNotificationDemand() {
        let shouldRetainDemand = hasAnyRenderEventSubscribers
        if shouldRetainDemand {
            if releaseFrameDemand == nil {
                releaseFrameDemand = GhosttyNSView.retainRenderedFrameNotifications()
            }
            if releaseTickDemand == nil {
                releaseTickDemand = GhosttyApp.retainTickNotifications()
            }
        } else {
            releaseFrameDemand?()
            releaseFrameDemand = nil
            releaseTickDemand?()
            releaseTickDemand = nil
            pendingSurfaceIDs.removeAll()
            hasPendingGlobalUpdate = false
            isEmitFlushScheduled = false
            renderGridStatesBySurfaceID.removeAll()
            cancelAllPreviewEmissionTasks()
        }
    }

    private func enqueueTerminalUpdate(surfaceID: UUID?) {
        guard hasAnyRenderEventSubscribers else {
            refreshNotificationDemand()
            return
        }
        if let surfaceID {
            pendingSurfaceIDs.insert(surfaceID)
        } else {
            hasPendingGlobalUpdate = true
        }
        guard !isEmitFlushScheduled else { return }
        isEmitFlushScheduled = true
        Task { @MainActor [weak self] in
            self?.flushTerminalUpdates()
        }
    }

    private func flushTerminalUpdates() {
        isEmitFlushScheduled = false
        guard hasAnyRenderEventSubscribers else {
            refreshNotificationDemand()
            return
        }
        let shouldEmitUpdatedEvents = MobileHostService.hasEventSubscribers(topic: "terminal.updated")
        let renderGridDemand = effectiveRenderGridDemand
        let shouldEmitRenderGridEvents = renderGridDemand.hasDemand
        let surfaceIDs = pendingSurfaceIDs
        let shouldEmitGlobal = hasPendingGlobalUpdate
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false

        if shouldEmitUpdatedEvents, shouldEmitGlobal {
            MobileHostService.emitEvent(topic: "terminal.updated", payload: [:])
        } else if shouldEmitUpdatedEvents {
            for surfaceID in surfaceIDs {
                MobileHostService.emitEvent(
                    topic: "terminal.updated",
                    payload: ["surface_id": surfaceID.uuidString]
                )
            }
        }

        guard shouldEmitRenderGridEvents else { return }
        let renderSurfaceIDs: Set<UUID>
        if surfaceIDs.isEmpty, shouldEmitGlobal {
            if renderGridDemand.includesLegacyAll {
                renderSurfaceIDs = Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id))
            } else {
                renderSurfaceIDs = Set(renderGridDemand.surfaceIDs.compactMap(UUID.init(uuidString:)))
            }
        } else {
            renderSurfaceIDs = Set(surfaceIDs.filter {
                renderGridDemand.contains(surfaceID: $0.uuidString)
            })
        }
        for surfaceID in renderSurfaceIDs {
            if renderGridDemand.isFocused(surfaceID: surfaceID.uuidString) {
                pendingPreviewEmissionTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
                emitRenderGrid(surfaceID: surfaceID)
            } else {
                enqueuePreviewEmission(surfaceID: surfaceID)
            }
        }
    }

    private func enqueuePreviewEmission(surfaceID: UUID) {
        let now = previewClock.now
        guard let lastEmission = lastPreviewEmissionBySurfaceID[surfaceID] else {
            emitRenderGrid(surfaceID: surfaceID)
            return
        }
        let deadline = lastEmission.advanced(by: previewUpdateInterval)
        guard now < deadline else {
            pendingPreviewEmissionTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
            emitRenderGrid(surfaceID: surfaceID)
            return
        }
        guard pendingPreviewEmissionTasksBySurfaceID[surfaceID] == nil else { return }
        pendingPreviewEmissionTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Intentional bounded preview cadence delay; demand changes cancel it.
                try await self.previewClock.sleep(until: deadline)
            } catch {
                return
            }
            self.pendingPreviewEmissionTasksBySurfaceID.removeValue(forKey: surfaceID)
            let demand = self.effectiveRenderGridDemand
            guard demand.contains(surfaceID: surfaceID.uuidString) else { return }
            self.emitRenderGrid(surfaceID: surfaceID)
        }
    }

    private func emitRenderGrid(surfaceID: UUID) {
        lastPreviewEmissionBySurfaceID[surfaceID] = previewClock.now
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              let snapshot = surface.mobileRenderGridFrame(stateSeq: stateSeq, full: true) else {
            renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
            return
        }

        guard let emission = try? snapshot.frame.renderGridEmission(
            comparedTo: renderGridStatesBySurfaceID[surfaceID]
        ) else { return }
        let frame = emission.frame
        renderGridStatesBySurfaceID[surfaceID] = emission.state
        guard let payload = try? frame.jsonObject() else { return }
        MobileHostService.emitEvent(topic: "terminal.render_grid", payload: payload)
        #if DEBUG
        cmuxDebugLog(
            "mobile.render_grid surface=\(surfaceID.uuidString.prefix(8)) full=\(frame.full) " +
                "cleared=\(frame.clearedRows.count) spans=\(frame.rowSpans.count) seq=\(frame.stateSeq)"
        )
        #endif
    }

    private func resetEmissionState(surfaceID: UUID) {
        renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
        lastPreviewEmissionBySurfaceID.removeValue(forKey: surfaceID)
        pendingPreviewEmissionTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
    }

    private func cancelAllPreviewEmissionTasks() {
        for task in pendingPreviewEmissionTasksBySurfaceID.values {
            task.cancel()
        }
        pendingPreviewEmissionTasksBySurfaceID.removeAll()
        lastPreviewEmissionBySurfaceID.removeAll()
    }

    #if DEBUG
    func debugResetRenderGridCacheForTesting() {
        renderGridStatesBySurfaceID.removeAll()
    }

    var debugRenderGridCacheCountForTesting: Int {
        renderGridStatesBySurfaceID.count
    }

    var debugIsRetainingNotificationDemandForTesting: Bool {
        releaseFrameDemand != nil && releaseTickDemand != nil
    }

    var debugRenderGridDemandForTesting: MobileRenderGridDemandSummary {
        effectiveRenderGridDemand
    }
    #endif
}
