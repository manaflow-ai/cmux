import CMUXMobileCore
import Foundation

/// Pushes terminal render events only while a mobile client is actively subscribed.
/// Ghostty notification demand is tied to subscriptions so the desktop terminal
/// path is untouched when no iPhone/iPad is attached.
@MainActor
final class MobileTerminalRenderObserver {
    static let shared = MobileTerminalRenderObserver()

    private struct RenderGridState {
        var columns: Int
        var rows: Int
        var stateSeq: UInt64
        var rowTexts: [String]
    }

    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalUpdate = false
    private var isEmitFlushScheduled = false
    private var renderGridStatesBySurfaceID: [UUID: RenderGridState] = [:]

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
    }

    func noteTerminalBytes(surfaceID: UUID) {
        guard MobileHostService.hasEventSubscribers(topic: "terminal.render_grid") else { return }
        pendingSurfaceIDs.insert(surfaceID)
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
            MobileHostService.hasEventSubscribers(topic: "terminal.render_grid")
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
        let shouldEmitRenderGridEvents = MobileHostService.hasEventSubscribers(topic: "terminal.render_grid")
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
            renderSurfaceIDs = Set(TerminalSurfaceRegistry.shared.allSurfaces().map(\.id))
        } else {
            renderSurfaceIDs = surfaceIDs
        }
        for surfaceID in renderSurfaceIDs {
            emitRenderGrid(surfaceID: surfaceID)
        }
    }

    private func emitRenderGrid(surfaceID: UUID) {
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let surface = TerminalSurfaceRegistry.shared.surface(id: surfaceID),
              let snapshot = surface.mobileRenderGridFrame(stateSeq: stateSeq, full: true) else {
            renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
            return
        }

        let previous = renderGridStatesBySurfaceID[surfaceID]
        let nextRows = snapshot.rows
        let frame: MobileTerminalRenderGridFrame
        if let previous,
           previous.columns == snapshot.frame.columns,
           previous.rows == snapshot.frame.rows {
            var changedRows = Set<Int>()
            let count = min(previous.rowTexts.count, nextRows.count)
            for index in 0..<count where previous.rowTexts[index] != nextRows[index] {
                changedRows.insert(index)
            }

            if changedRows.isEmpty {
                guard previous.stateSeq != snapshot.frame.stateSeq else { return }
                guard let emptyFrame = try? MobileTerminalRenderGridFrame(
                    surfaceID: snapshot.frame.surfaceID,
                    stateSeq: snapshot.frame.stateSeq,
                    columns: snapshot.frame.columns,
                    rows: snapshot.frame.rows,
                    full: false,
                    rowSpans: []
                ) else {
                    return
                }
                frame = emptyFrame
            } else {
                guard let deltaFrame = try? MobileTerminalRenderGridFrame.fromPlainRows(
                    surfaceID: snapshot.frame.surfaceID,
                    stateSeq: snapshot.frame.stateSeq,
                    columns: snapshot.frame.columns,
                    rows: snapshot.frame.rows,
                    text: nextRows.joined(separator: "\n"),
                    full: false,
                    changedRows: changedRows
                ) else {
                    return
                }
                frame = deltaFrame
            }
        } else {
            frame = snapshot.frame
        }

        renderGridStatesBySurfaceID[surfaceID] = RenderGridState(
            columns: frame.columns,
            rows: frame.rows,
            stateSeq: frame.stateSeq,
            rowTexts: nextRows
        )
        guard let payload = try? frame.jsonObject() else { return }
        MobileHostService.emitEvent(topic: "terminal.render_grid", payload: payload)
        #if DEBUG
        cmuxDebugLog(
            "mobile.render_grid surface=\(surfaceID.uuidString.prefix(8)) full=\(frame.full) " +
                "cleared=\(frame.clearedRows.count) spans=\(frame.rowSpans.count) seq=\(frame.stateSeq)"
        )
        #endif
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
    #endif
}
