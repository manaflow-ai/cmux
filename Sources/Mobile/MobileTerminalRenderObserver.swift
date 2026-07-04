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
    private var pendingByteEventsBySurfaceID: [UUID: PendingTerminalBytes] = [:]
    private let pendingBytesBudgetPerSurface = 256 * 1024
    private let maxDeferredHybridByteFlushRetries = 2

    private struct PendingTerminalBytes {
        var seq: UInt64
        var data: Data
        var overflowed = false
        var renderGridMissCount = 0

        init(seq: UInt64, data: Data, budget: Int) {
            self.seq = seq
            self.data = data
            enforceBudget(budget)
        }

        mutating func append(seq nextSeq: UInt64, data nextData: Data, budget: Int) {
            renderGridMissCount = 0
            let currentEnd = seq &+ UInt64(data.count)
            if currentEnd == nextSeq {
                data.append(nextData)
            } else if nextSeq > currentEnd {
                seq = nextSeq
                data = nextData
                overflowed = true
            } else {
                let overlap = currentEnd - nextSeq
                guard overlap < UInt64(nextData.count) else {
                    return
                }
                data.append(contentsOf: nextData.dropFirst(Int(overlap)))
            }
            enforceBudget(budget)
        }

        mutating func recordRenderGridMiss(maxRetries: Int) -> Bool {
            renderGridMissCount += 1
            return renderGridMissCount <= maxRetries
        }

        private mutating func enforceBudget(_ budget: Int) {
            guard budget > 0 else {
                seq &+= UInt64(data.count)
                data.removeAll(keepingCapacity: false)
                overflowed = true
                return
            }
            let excess = data.count - budget
            guard excess > 0 else { return }
            // Keep a bounded tail so legacy hybrid clients still receive a
            // sequenced byte event and can detect the missing prefix.
            data.removeFirst(excess)
            seq &+= UInt64(excess)
            overflowed = true
        }
    }

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
        pendingByteEventsBySurfaceID.removeAll()
    }

    func noteTerminalBytes(surfaceID: UUID) {
        guard MobileHostService.hasEventSubscribers(topic: "terminal.render_grid") else { return }
        pendingSurfaceIDs.insert(surfaceID)
        // The byte tee runs before Ghostty's VT parser consumes the bytes, and
        // the hop back to the main actor can land after the current tick/frame
        // notification already fired. Schedule a fresh Ghostty tick so every
        // byte-backed pending surface gets one post-parser render-grid flush.
        GhosttyApp.shared.scheduleTick()
    }

    func enqueueTerminalBytesEventAfterRender(surfaceID: UUID, seq: UInt64, data: Data) {
        if var pending = pendingByteEventsBySurfaceID[surfaceID] {
            pending.append(seq: seq, data: data, budget: pendingBytesBudgetPerSurface)
            pendingByteEventsBySurfaceID[surfaceID] = pending
        } else {
            pendingByteEventsBySurfaceID[surfaceID] = PendingTerminalBytes(
                seq: seq,
                data: data,
                budget: pendingBytesBudgetPerSurface
            )
        }
        noteTerminalBytes(surfaceID: surfaceID)
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
            var orderedEvents: [(
                topic: String,
                payload: [String: Any],
                requiredTopics: Set<String>,
                excludedTopics: Set<String>
            )] = []
            for surfaceID in Array(pendingByteEventsBySurfaceID.keys) {
                if let payload = pendingTerminalBytesPayload(surfaceID: surfaceID) {
                    orderedEvents.append((
                        topic: "terminal.bytes",
                        payload: payload,
                        requiredTopics: ["terminal.render_grid"],
                        excludedTopics: []
                    ))
                }
            }
            if !orderedEvents.isEmpty {
                MobileHostService.emitConstrainedEventsInOrder(orderedEvents)
            }
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
        guard hasAnyRenderEventSubscribers || !pendingByteEventsBySurfaceID.isEmpty else {
            refreshNotificationDemand()
            return
        }
        let shouldEmitUpdatedEvents = MobileHostService.hasEventSubscribers(topic: "terminal.updated")
        let shouldEmitRenderGridEvents = MobileHostService.hasEventSubscribers(topic: "terminal.render_grid")
        let surfaceIDs = pendingSurfaceIDs
        let pendingByteSurfaceIDs = Set(pendingByteEventsBySurfaceID.keys)
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

        if shouldEmitRenderGridEvents {
            let renderSurfaceIDs: Set<UUID>
            if surfaceIDs.isEmpty, shouldEmitGlobal {
                renderSurfaceIDs = Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id))
            } else {
                renderSurfaceIDs = surfaceIDs
            }
            var orderedEvents: [(
                topic: String,
                payload: [String: Any],
                requiredTopics: Set<String>,
                excludedTopics: Set<String>
            )] = []
            var deferredHybridByteSurfaceIDs = Set<UUID>()
            for surfaceID in renderSurfaceIDs {
                guard let renderPayload = renderGridPayload(surfaceID: surfaceID) else {
                    if pendingByteEventsBySurfaceID[surfaceID] != nil,
                       hasTerminalSurface(surfaceID: surfaceID) {
                        if shouldDeferHybridByteFlush(surfaceID: surfaceID) {
                            deferredHybridByteSurfaceIDs.insert(surfaceID)
                        } else {
                            pendingByteEventsBySurfaceID.removeValue(forKey: surfaceID)
                        }
                    } else {
                        pendingByteEventsBySurfaceID.removeValue(forKey: surfaceID)
                    }
                    continue
                }
                orderedEvents.append((
                    topic: "terminal.render_grid",
                    payload: renderPayload,
                    requiredTopics: [],
                    excludedTopics: []
                ))
                if let payload = pendingTerminalBytesPayload(surfaceID: surfaceID) {
                    orderedEvents.append((
                        topic: "terminal.bytes",
                        payload: payload,
                        requiredTopics: ["terminal.render_grid"],
                        excludedTopics: []
                    ))
                }
            }
            for surfaceID in surfaceIDs.union(pendingByteSurfaceIDs).subtracting(renderSurfaceIDs) {
                if hasTerminalSurface(surfaceID: surfaceID) {
                    if shouldDeferHybridByteFlush(surfaceID: surfaceID) {
                        deferredHybridByteSurfaceIDs.insert(surfaceID)
                    } else {
                        pendingByteEventsBySurfaceID.removeValue(forKey: surfaceID)
                    }
                } else {
                    pendingByteEventsBySurfaceID.removeValue(forKey: surfaceID)
                }
            }
            pendingSurfaceIDs.formUnion(deferredHybridByteSurfaceIDs)
            if !deferredHybridByteSurfaceIDs.isEmpty {
                // Keep byte-backed hybrid surfaces moving after an early flush
                // races ahead of Ghostty's VT parser.
                GhosttyApp.shared.scheduleTick()
            }
            if !orderedEvents.isEmpty {
                MobileHostService.emitConstrainedEventsInOrder(orderedEvents)
            }
        } else {
            var orderedEvents: [(
                topic: String,
                payload: [String: Any],
                requiredTopics: Set<String>,
                excludedTopics: Set<String>
            )] = []
            for surfaceID in surfaceIDs.union(pendingByteSurfaceIDs) {
                if let payload = pendingTerminalBytesPayload(surfaceID: surfaceID) {
                    orderedEvents.append((
                        topic: "terminal.bytes",
                        payload: payload,
                        requiredTopics: ["terminal.render_grid"],
                        excludedTopics: []
                    ))
                }
            }
            if !orderedEvents.isEmpty {
                MobileHostService.emitConstrainedEventsInOrder(orderedEvents)
            }
        }
    }

    private func shouldDeferHybridByteFlush(surfaceID: UUID) -> Bool {
        guard var pending = pendingByteEventsBySurfaceID[surfaceID] else { return false }
        let shouldDefer = pending.recordRenderGridMiss(maxRetries: maxDeferredHybridByteFlushRetries)
        pendingByteEventsBySurfaceID[surfaceID] = pending
        return shouldDefer
    }

    private func pendingTerminalBytesPayload(surfaceID: UUID) -> [String: Any]? {
        guard let pending = pendingByteEventsBySurfaceID.removeValue(forKey: surfaceID) else {
            return nil
        }
        guard !pending.data.isEmpty else { return nil }
        return [
            "surface_id": surfaceID.uuidString,
            "seq": pending.seq,
            "data_b64": pending.data.base64EncodedString(),
        ]
    }

    private func hasTerminalSurface(surfaceID: UUID) -> Bool {
        GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil
    }

    private func renderGridPayload(surfaceID: UUID) -> [String: Any]? {
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              let snapshot = surface.mobileRenderGridFrame(stateSeq: stateSeq, full: true) else {
            renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
            return nil
        }

        let forceFullFrame = pendingByteEventsBySurfaceID[surfaceID]?.overflowed == true
        let frame: MobileTerminalRenderGridFrame
        if forceFullFrame {
            frame = snapshot.frame
            renderGridStatesBySurfaceID[surfaceID] = frame.emissionState
        } else {
            guard let emission = try? snapshot.frame.renderGridEmission(
                comparedTo: renderGridStatesBySurfaceID[surfaceID]
            ) else { return nil }
            frame = emission.frame
            renderGridStatesBySurfaceID[surfaceID] = emission.state
        }
        guard var payload = try? frame.jsonObject() else { return nil }
        if forceFullFrame {
            payload["hybrid_bytes_overflowed"] = true
        }
        #if DEBUG
        cmuxDebugLog(
            "mobile.render_grid surface=\(surfaceID.uuidString.prefix(8)) full=\(frame.full) " +
                "cleared=\(frame.clearedRows.count) spans=\(frame.rowSpans.count) seq=\(frame.stateSeq)"
        )
        #endif
        return payload
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
