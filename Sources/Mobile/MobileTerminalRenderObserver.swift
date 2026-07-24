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
    private var hasPendingThemeInvalidation = false
    private var pendingThemeSurfaceIDs = Set<UUID>()
    private var isEmitFlushScheduled = false
    private var renderGridStatesBySurfaceID:
        [UUID: [MobileTerminalRenderGridFrame.Anchor: MobileTerminalRenderGridEmissionState]] = [:]
    private var terminalThemesBySurfaceID: [UUID: TerminalTheme] = [:]
    private var terminalConfigThemesBySurfaceID: [UUID: TerminalTheme] = [:]
    private var runtimeSurfaceGenerationsBySurfaceID: [UUID: UInt64] = [:]
    private var reconciledSurfaceTopologyGeneration: UInt64?
    private var cachedTerminalTheme: TerminalTheme = .monokai
    private var hasLoadedTerminalTheme = false
    private var terminalThemeRevision: UInt64 = 0
    private lazy var themeInvalidationScheduler = MobileTerminalThemeInvalidationScheduler {
        [weak self] surfaceIDs in
        self?.enqueueCoalescedThemeUpdates(surfaceIDs)
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
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateTerminalThemes()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateTerminalThemes()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let surfaceID = notification.object as? UUID else { return }
                guard MobileHostService.hasEventSubscribers(topic: "terminal.render_grid") else { return }
                self?.themeInvalidationScheduler.schedule(surfaceID: surfaceID)
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
        hasPendingThemeInvalidation = false
        pendingThemeSurfaceIDs.removeAll()
        themeInvalidationScheduler.cancel()
        isEmitFlushScheduled = false
        renderGridStatesBySurfaceID.removeAll()
        terminalThemesBySurfaceID.removeAll()
        terminalConfigThemesBySurfaceID.removeAll()
        runtimeSurfaceGenerationsBySurfaceID.removeAll()
        hasLoadedTerminalTheme = false
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
        let hasRenderGridSubscribers = MobileHostService.hasEventSubscribers(topic: "terminal.render_grid")
        if hasRenderGridSubscribers, !hasLoadedTerminalTheme {
            refreshTerminalTheme()
        } else if !hasRenderGridSubscribers {
            clearRenderGridCaches()
            hasLoadedTerminalTheme = false
        }
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
            hasPendingThemeInvalidation = false
            pendingThemeSurfaceIDs.removeAll()
            themeInvalidationScheduler.cancel()
            isEmitFlushScheduled = false
            clearRenderGridCaches()
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
        scheduleTerminalUpdateFlush()
    }

    private func enqueueCoalescedThemeUpdates(_ surfaceIDs: Set<UUID>) {
        guard MobileHostService.hasEventSubscribers(topic: "terminal.render_grid") else { return }
        pendingThemeSurfaceIDs.formUnion(surfaceIDs)
        pendingSurfaceIDs.formUnion(surfaceIDs)
        scheduleTerminalUpdateFlush()
    }

    private func scheduleTerminalUpdateFlush() {
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
        let shouldEmitAllThemes = hasPendingThemeInvalidation
        let themeSurfaceIDs = pendingThemeSurfaceIDs
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        hasPendingThemeInvalidation = false
        pendingThemeSurfaceIDs.removeAll()

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

        guard shouldEmitRenderGridEvents else {
            clearRenderGridCaches()
            return
        }
        reconcileRenderGridCachesIfSurfaceTopologyChanged()
        let renderSurfaceIDs: Set<UUID>
        if shouldEmitAllThemes || (surfaceIDs.isEmpty && shouldEmitGlobal) {
            renderSurfaceIDs = Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id))
        } else {
            renderSurfaceIDs = surfaceIDs.union(themeSurfaceIDs)
        }
        for surfaceID in renderSurfaceIDs {
            emitRenderGrid(
                surfaceID: surfaceID,
                forceIncludeTheme: shouldEmitAllThemes
                    || themeSurfaceIDs.contains(surfaceID)
            )
        }
    }

    private func emitRenderGrid(surfaceID: UUID, forceIncludeTheme: Bool) {
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        let renderCapture = MobileTerminalByteTee.shared.nextRenderCaptureIdentity(surfaceID: surfaceID)
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              surface.surface != nil else {
            clearRenderGridCache(surfaceID: surfaceID)
            return
        }
        let runtimeGeneration = surface.runtimeSurfaceGeneration
        let didReplaceRuntimeSurface = runtimeSurfaceGenerationsBySurfaceID[surfaceID]
            .map { $0 != runtimeGeneration } ?? false
        if didReplaceRuntimeSurface {
            clearRenderGridCache(surfaceID: surfaceID)
        }
        let includeTheme = forceIncludeTheme
            || renderGridStatesBySurfaceID[surfaceID]?.values
                .contains { $0.terminalTheme != nil } != true
            || didReplaceRuntimeSurface

        // Produce one payload per anchor with a live subscriber. Viewport (v1)
        // mirrors the Mac's scroll position; screen (v2) anchors to the active
        // area so the phone owns its local viewport/scrollback. An empty
        // registry (subscribers predating anchor negotiation) means v1 only.
        let activeAnchors = MobileTerminalRenderGridAnchorRegistry.activeAnchors()
        var anchors: [MobileTerminalRenderGridFrame.Anchor] = []
        if activeAnchors.contains(.viewport) || activeAnchors.isEmpty { anchors.append(.viewport) }
        if activeAnchors.contains(.screen) { anchors.append(.screen) }

        runtimeSurfaceGenerationsBySurfaceID[surfaceID] = runtimeGeneration
        // Both anchor variants describe the same terminal state at the same
        // capture, so they share one theme decision and one theme revision.
        var sharedTheme: (config: TerminalTheme?, theme: TerminalTheme, revision: UInt64)?
        var payloadsByAnchor: [MobileTerminalRenderGridFrame.Anchor: [String: Any]] = [:]
        var emittedByAnchor: [MobileTerminalRenderGridFrame.Anchor: MobileTerminalRenderGridFrame] = [:]

        for anchor in anchors {
            guard let emitted = emitRenderGridFrame(
                surface: surface,
                surfaceID: surfaceID,
                anchor: anchor,
                stateSeq: stateSeq,
                renderCapture: renderCapture,
                includeTheme: includeTheme,
                forceIncludeTheme: forceIncludeTheme || didReplaceRuntimeSurface,
                sharedTheme: &sharedTheme
            ) else { continue }
            guard let payload = try? emitted.jsonObject() else { continue }
            payloadsByAnchor[anchor] = payload
            emittedByAnchor[anchor] = emitted
        }
        guard !payloadsByAnchor.isEmpty else { return }
        MobileHostService.emitRenderGridEvent(payloadsByAnchor: payloadsByAnchor)
        #if DEBUG
        for (anchor, frame) in emittedByAnchor {
            cmuxDebugLog(
                "mobile.render_grid surface=\(surfaceID.uuidString.prefix(8)) anchor=\(anchor.rawValue) " +
                    "full=\(frame.full) cleared=\(frame.clearedRows.count) spans=\(frame.rowSpans.count) " +
                    "scrolled=\(frame.scrolledRows) sbRows=\(frame.scrollbackRows) " +
                    "seq=\(frame.stateSeq) revision=\(frame.renderRevision)"
            )
        }
        #endif
    }

    /// Exports, themes, and diffs one anchor variant for a surface, handling
    /// the emission's re-export request: a screen-anchored burst delta must
    /// carry the history rows that scrolled through between captures, and a
    /// screen-anchored full must carry deep scrollback so a replay reset
    /// preserves the consumer's local history.
    private func emitRenderGridFrame(
        surface: TerminalSurface,
        surfaceID: UUID,
        anchor: MobileTerminalRenderGridFrame.Anchor,
        stateSeq: UInt64,
        renderCapture: (epoch: String, revision: UInt64),
        includeTheme: Bool,
        forceIncludeTheme: Bool,
        sharedTheme: inout (config: TerminalTheme?, theme: TerminalTheme, revision: UInt64)?
    ) -> MobileTerminalRenderGridFrame? {
        // Event-lane fulls stay scrollback-free for BOTH anchors: a screen-
        // anchored full without scrollback replays as a history-preserving
        // in-place repaint on the consumer, so deep hydration is needed only
        // on the explicit replay RPC (cold attach / surface rebuild). Carrying
        // 4000 rows here would turn every mid-stream reset into a multi-MB
        // frame and starve the event lane during replay-barrier churn.
        let fullScrollbackTarget = 0
        var scrollbackLines = 0
        var allowScrollbackRequest = true
        while true {
            guard let snapshot = surface.mobileRenderGridFrame(
                    stateSeq: stateSeq,
                    renderEpoch: renderCapture.epoch,
                    renderRevision: renderCapture.revision,
                    full: true,
                    scrollbackLines: scrollbackLines,
                    includeTheme: includeTheme,
                    anchor: anchor
                  ) else {
                clearRenderGridCache(surfaceID: surfaceID)
                return nil
            }
            var themedFrame = snapshot.frame
            let resolvedTheme: (config: TerminalTheme?, theme: TerminalTheme, revision: UInt64)
            if let sharedTheme {
                resolvedTheme = sharedTheme
            } else {
                let configTheme = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
                    candidate: themedFrame.terminalConfigTheme,
                    cached: terminalConfigThemesBySurfaceID[surfaceID],
                    fallbackBoldColor: cachedTerminalTheme.boldColor
                )
                if snapshot.frame.terminalConfigTheme != nil, let configTheme {
                    terminalConfigThemesBySurfaceID[surfaceID] = configTheme
                }
                let candidateTheme = (themedFrame.terminalTheme
                    ?? terminalThemesBySurfaceID[surfaceID]
                    ?? cachedTerminalTheme).applyingSurfaceColors(from: snapshot.frame)
                let themeDecision = MobileTerminalThemeEmissionDecision.resolve(
                    candidate: candidateTheme,
                    cached: terminalThemesBySurfaceID[surfaceID],
                    forceCandidate: forceIncludeTheme
                )
                if themeDecision.shouldScheduleCandidate {
                    themeInvalidationScheduler.schedule(surfaceID: surfaceID)
                } else {
                    terminalThemesBySurfaceID[surfaceID] = themeDecision.theme
                }
                resolvedTheme = (
                    config: configTheme,
                    theme: themeDecision.theme,
                    revision: nextTerminalThemeRevision()
                )
                sharedTheme = resolvedTheme
            }
            themedFrame.terminalConfigTheme = resolvedTheme.config
            themedFrame.terminalTheme = resolvedTheme.theme
            themedFrame.terminalThemeRevision = resolvedTheme.revision

            guard let emission = try? themedFrame.renderGridEmission(
                comparedTo: renderGridStatesBySurfaceID[surfaceID]?[anchor],
                fullScrollbackTarget: fullScrollbackTarget,
                allowScrollbackRequest: allowScrollbackRequest
            ) else { return nil }
            switch emission {
            case .emit(let frame, let state):
                renderGridStatesBySurfaceID[surfaceID, default: [:]][anchor] = state
                return frame
            case .needsScrollback(let rows):
                // Re-export once with the requested history rows; the retry
                // recomputes from the fresh capture and must emit with
                // whatever it carries (content may advance between exports).
                scrollbackLines = rows
                allowScrollbackRequest = false
            case .none:
                return nil
            }
        }
    }

    private func refreshTerminalTheme() {
        cachedTerminalTheme = TerminalTheme.currentMacTerminalThemeSnapshot()
        hasLoadedTerminalTheme = true
    }

    /// Rebase the screen-anchored delta chain onto an authoritative replay
    /// frame served outside the event lane (the `mobile.terminal.replay` RPC).
    /// The next emitted delta is then diffed against exactly the state the
    /// consumer just applied, so its `deltaBaseHistoryRows` chains from the
    /// replay even while output streams. Without this, a mid-stream replay
    /// leaves the emission baseline behind the delivered state and every
    /// subsequent delta breaks the consumer's continuity check.
    ///
    /// Shared across screen-anchored subscribers: a replay served to one phone
    /// rebases the chain for all of them; the others recover through their own
    /// continuity check. Same-surface multi-phone viewing is rare.
    func adoptReplayBaseline(_ frame: MobileTerminalRenderGridFrame, surfaceID: UUID) {
        guard frame.anchor == .screen else { return }
        renderGridStatesBySurfaceID[surfaceID, default: [:]][.screen] = frame.emissionState
    }

    func decorateReplayFrame(_ frame: MobileTerminalRenderGridFrame) -> MobileTerminalRenderGridFrame {
        if !hasLoadedTerminalTheme { refreshTerminalTheme() }
        var themedFrame = frame
        themedFrame.terminalTheme = (frame.terminalTheme ?? cachedTerminalTheme)
            .applyingSurfaceColors(from: frame)
        themedFrame.terminalConfigTheme = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
            candidate: frame.terminalConfigTheme,
            cached: nil,
            fallbackBoldColor: cachedTerminalTheme.boldColor
        )
        themedFrame.terminalThemeRevision = nextTerminalThemeRevision()
        return themedFrame
    }

    private func nextTerminalThemeRevision() -> UInt64 {
        terminalThemeRevision &+= 1
        return terminalThemeRevision
    }

    private func invalidateTerminalThemes() {
        guard MobileHostService.hasEventSubscribers(topic: "terminal.render_grid") else {
            hasLoadedTerminalTheme = false
            return
        }
        refreshTerminalTheme()
        hasPendingThemeInvalidation = true
        enqueueTerminalUpdate(surfaceID: nil)
    }

    private func reconcileRenderGridCachesIfSurfaceTopologyChanged() {
        let registry = GhosttyApp.terminalSurfaceRegistry
        let generation = registry.topologyGeneration
        guard reconciledSurfaceTopologyGeneration != generation else { return }
        let liveSurfaceIDs = Set(registry.allSurfaces().map(\.id))
        renderGridStatesBySurfaceID = renderGridStatesBySurfaceID.filter { liveSurfaceIDs.contains($0.key) }
        terminalThemesBySurfaceID = terminalThemesBySurfaceID.filter { liveSurfaceIDs.contains($0.key) }
        terminalConfigThemesBySurfaceID = terminalConfigThemesBySurfaceID.filter { liveSurfaceIDs.contains($0.key) }
        runtimeSurfaceGenerationsBySurfaceID = runtimeSurfaceGenerationsBySurfaceID.filter {
            liveSurfaceIDs.contains($0.key)
        }
        // Store the revision read before enumeration. If topology changed during
        // the snapshot, the next flush observes a newer value and reconciles again.
        reconciledSurfaceTopologyGeneration = generation
    }

    private func clearRenderGridCache(surfaceID: UUID) {
        renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
        terminalThemesBySurfaceID.removeValue(forKey: surfaceID)
        terminalConfigThemesBySurfaceID.removeValue(forKey: surfaceID)
        runtimeSurfaceGenerationsBySurfaceID.removeValue(forKey: surfaceID)
    }

    private func clearRenderGridCaches() {
        renderGridStatesBySurfaceID.removeAll()
        terminalThemesBySurfaceID.removeAll()
        terminalConfigThemesBySurfaceID.removeAll()
        runtimeSurfaceGenerationsBySurfaceID.removeAll()
        reconciledSurfaceTopologyGeneration = nil
    }

    #if DEBUG
    var debugIsRetainingNotificationDemandForTesting: Bool {
        releaseFrameDemand != nil && releaseTickDemand != nil
    }
    #endif
}
