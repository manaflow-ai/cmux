import CMUXMobileCore
import CmuxTerminal
import CmuxWorkspaceShare
import Foundation
import os

nonisolated private let shareGridStreamerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceShareGrid"
)

/// Streams per-pane render-grid frames to the share socket, but only for
/// panes with at least one subscribed guest (driven by `guest-sub` messages).
/// Mirrors `MobileTerminalRenderObserver`: Ghostty frame/tick notification
/// demand is retained only while any pane is subscribed, updates coalesce per
/// runloop hop, and per-surface emission state drives full-vs-delta frames.
@MainActor
final class ShareGridStreamer {
    /// Encoded binary grid frame ready for the socket.
    var sendBinary: ((Data) -> Bool)?

    private struct PaneSubscription {
        var ws: String
        var count: Int
    }

    /// Keyed by the pane's surface UUID (`TerminalSurface.id`).
    private var subscriptionsBySurfaceID: [UUID: PaneSubscription] = [:]

    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalUpdate = false
    private var pendingThemeSurfaceIDs = Set<UUID>()
    private var hasPendingThemeInvalidation = false
    private var isEmitFlushScheduled = false
    private var emitFlushTask: Task<Void, Never>?
    private var emissionStatesBySurfaceID: [UUID: MobileTerminalRenderGridEmissionState] = [:]
    private var terminalThemesBySurfaceID: [UUID: TerminalTheme] = [:]
    private var terminalConfigThemesBySurfaceID: [UUID: TerminalTheme] = [:]
    private var runtimeSurfaceGenerationsBySurfaceID: [UUID: UInt64] = [:]
    private var cachedTerminalTheme: TerminalTheme = .monokai
    private var hasLoadedTerminalTheme = false
    private var terminalThemeRevision: UInt64 = 0
    private lazy var themeInvalidationScheduler = MobileTerminalThemeInvalidationScheduler {
        [weak self] surfaceIDs in
        self?.enqueueCoalescedThemeUpdates(surfaceIDs)
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let view = notification.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else { return }
                self?.enqueueUpdate(surfaceID: surfaceID)
            }
        })
        // Tick notifications cover surfaces whose window is off screen (a
        // background workspace driven by output still updates its guests).
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.enqueueUpdate(surfaceID: nil)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateTerminalThemes() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateTerminalThemes() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySurfaceThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let surfaceID = notification.object as? UUID else { return }
                guard self.subscriptionsBySurfaceID[surfaceID] != nil else { return }
                self.themeInvalidationScheduler.schedule(surfaceID: surfaceID)
            }
        })
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        subscriptionsBySurfaceID.removeAll()
        refreshNotificationDemand()
        themeInvalidationScheduler.cancel()
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        hasPendingThemeInvalidation = false
        pendingThemeSurfaceIDs.removeAll()
        isEmitFlushScheduled = false
        emitFlushTask?.cancel()
        emitFlushTask = nil
        clearEmissionCaches()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseFrameDemand?()
        releaseTickDemand?()
        emitFlushTask?.cancel()
    }

    /// Applies a `guest-sub` update. Any count increase (including 0 -> N)
    /// forces a fresh full frame with theme: grid deltas need continuity, so
    /// a new subscriber must never start mid-delta-stream.
    func setSubscriberCount(ws: String, pane: String, count: Int) {
        guard let surfaceID = UUID(uuidString: pane) else { return }
        let previous = subscriptionsBySurfaceID[surfaceID]?.count ?? 0
        if count <= 0 {
            subscriptionsBySurfaceID.removeValue(forKey: surfaceID)
            clearEmissionCache(surfaceID: surfaceID)
        } else {
            subscriptionsBySurfaceID[surfaceID] = PaneSubscription(ws: ws, count: count)
        }
        refreshNotificationDemand()
        if count > previous {
            emitFullFrame(surfaceID: surfaceID)
        }
    }

    /// Re-sends full frames for every subscribed pane (post-`resync`).
    func resendFullFrames() {
        for surfaceID in subscriptionsBySurfaceID.keys {
            emitFullFrame(surfaceID: surfaceID)
        }
    }

    private var hasAnySubscribers: Bool { !subscriptionsBySurfaceID.isEmpty }

    private func refreshNotificationDemand() {
        if hasAnySubscribers {
            if !hasLoadedTerminalTheme { refreshTerminalTheme() }
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
            clearEmissionCaches()
            hasLoadedTerminalTheme = false
        }
    }

    private func enqueueUpdate(surfaceID: UUID?) {
        // Hot path while sharing with no subscribed panes: notification demand
        // is released so this rarely fires; the guard keeps it allocation-free.
        guard hasAnySubscribers else { return }
        if let surfaceID {
            guard subscriptionsBySurfaceID[surfaceID] != nil else { return }
            pendingSurfaceIDs.insert(surfaceID)
        } else {
            hasPendingGlobalUpdate = true
        }
        scheduleEmitFlush()
    }

    private func enqueueCoalescedThemeUpdates(_ surfaceIDs: Set<UUID>) {
        guard hasAnySubscribers else { return }
        let subscribed = surfaceIDs.filter { subscriptionsBySurfaceID[$0] != nil }
        guard !subscribed.isEmpty else { return }
        pendingThemeSurfaceIDs.formUnion(subscribed)
        pendingSurfaceIDs.formUnion(subscribed)
        scheduleEmitFlush()
    }

    private func scheduleEmitFlush() {
        guard !isEmitFlushScheduled else { return }
        isEmitFlushScheduled = true
        emitFlushTask = Task { @MainActor [weak self] in
            self?.flushUpdates()
        }
    }

    private func flushUpdates() {
        emitFlushTask = nil
        isEmitFlushScheduled = false
        guard hasAnySubscribers else { return }
        let surfaceIDs = pendingSurfaceIDs
        let shouldEmitGlobal = hasPendingGlobalUpdate
        let shouldEmitAllThemes = hasPendingThemeInvalidation
        let themeSurfaceIDs = pendingThemeSurfaceIDs
        pendingSurfaceIDs.removeAll()
        hasPendingGlobalUpdate = false
        hasPendingThemeInvalidation = false
        pendingThemeSurfaceIDs.removeAll()

        let emitSurfaceIDs: Set<UUID>
        if shouldEmitAllThemes || shouldEmitGlobal {
            emitSurfaceIDs = Set(subscriptionsBySurfaceID.keys)
        } else {
            emitSurfaceIDs = surfaceIDs.union(themeSurfaceIDs)
        }
        for surfaceID in emitSurfaceIDs {
            emitRenderGrid(
                surfaceID: surfaceID,
                forceIncludeTheme: shouldEmitAllThemes || themeSurfaceIDs.contains(surfaceID)
            )
        }
    }

    private func emitFullFrame(surfaceID: UUID) {
        clearEmissionCache(surfaceID: surfaceID)
        emitRenderGrid(surfaceID: surfaceID, forceIncludeTheme: true)
    }

    private func emitRenderGrid(surfaceID: UUID, forceIncludeTheme: Bool) {
        guard let subscription = subscriptionsBySurfaceID[surfaceID] else { return }
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              surface.surface != nil else {
            clearEmissionCache(surfaceID: surfaceID)
            return
        }
        let runtimeGeneration = surface.runtimeSurfaceGeneration
        let didReplaceRuntimeSurface = runtimeSurfaceGenerationsBySurfaceID[surfaceID]
            .map { $0 != runtimeGeneration } ?? false
        if didReplaceRuntimeSurface {
            clearEmissionCache(surfaceID: surfaceID)
        }
        let includeTheme = forceIncludeTheme
            || emissionStatesBySurfaceID[surfaceID]?.terminalTheme == nil
            || didReplaceRuntimeSurface
        guard let snapshot = surface.mobileRenderGridFrame(
            stateSeq: stateSeq,
            full: true,
            includeTheme: includeTheme
        ) else {
            clearEmissionCache(surfaceID: surfaceID)
            return
        }

        var themedFrame = snapshot.frame
        let configTheme = MobileTerminalThemeEmissionDecision.resolveConfigTheme(
            candidate: themedFrame.terminalConfigTheme,
            cached: terminalConfigThemesBySurfaceID[surfaceID],
            fallbackBoldColor: cachedTerminalTheme.boldColor
        )
        themedFrame.terminalConfigTheme = configTheme
        if snapshot.frame.terminalConfigTheme != nil, let configTheme {
            terminalConfigThemesBySurfaceID[surfaceID] = configTheme
        }
        let candidateTheme = (themedFrame.terminalTheme
            ?? terminalThemesBySurfaceID[surfaceID]
            ?? cachedTerminalTheme).applyingSurfaceColors(from: snapshot.frame)
        let themeDecision = MobileTerminalThemeEmissionDecision.resolve(
            candidate: candidateTheme,
            cached: terminalThemesBySurfaceID[surfaceID],
            forceCandidate: forceIncludeTheme || didReplaceRuntimeSurface
        )
        themedFrame.terminalTheme = themeDecision.theme
        if themeDecision.shouldScheduleCandidate {
            themeInvalidationScheduler.schedule(surfaceID: surfaceID)
        } else {
            terminalThemesBySurfaceID[surfaceID] = themeDecision.theme
        }
        runtimeSurfaceGenerationsBySurfaceID[surfaceID] = runtimeGeneration
        terminalThemeRevision &+= 1
        themedFrame.terminalThemeRevision = terminalThemeRevision
        guard let emission = try? themedFrame.renderGridEmission(
            comparedTo: emissionStatesBySurfaceID[surfaceID]
        ) else { return }
        guard let payload = try? JSONEncoder().encode(emission.frame),
              let binary = ShareBinaryFrame.encode(
                  kind: ShareProtocolConstants.binaryKindGrid,
                  ws: subscription.ws,
                  pane: surfaceID.uuidString,
                  payload: payload
              ),
              sendBinary?(binary) == true else {
            // The client did not receive this state. Clearing the comparison
            // cache makes the next render notification reconcile with a full
            // frame instead of emitting a delta from unsent state.
            clearEmissionCache(surfaceID: surfaceID)
            shareGridStreamerLogger.warning(
                "A render-grid frame was rejected before share transport admission"
            )
            return
        }
        emissionStatesBySurfaceID[surfaceID] = emission.state
        #if DEBUG
        cmuxDebugLog(
            "share.render_grid surface=\(surfaceID.uuidString.prefix(8)) full=\(emission.frame.full) " +
                "spans=\(emission.frame.rowSpans.count) seq=\(emission.frame.stateSeq)"
        )
        #endif
    }

    private func refreshTerminalTheme() {
        cachedTerminalTheme = TerminalTheme.currentMacTerminalThemeSnapshot()
        hasLoadedTerminalTheme = true
    }

    private func invalidateTerminalThemes() {
        guard hasAnySubscribers else {
            hasLoadedTerminalTheme = false
            return
        }
        refreshTerminalTheme()
        hasPendingThemeInvalidation = true
        scheduleEmitFlush()
    }

    private func clearEmissionCache(surfaceID: UUID) {
        emissionStatesBySurfaceID.removeValue(forKey: surfaceID)
        terminalThemesBySurfaceID.removeValue(forKey: surfaceID)
        terminalConfigThemesBySurfaceID.removeValue(forKey: surfaceID)
        runtimeSurfaceGenerationsBySurfaceID.removeValue(forKey: surfaceID)
    }

    private func clearEmissionCaches() {
        emissionStatesBySurfaceID.removeAll()
        terminalThemesBySurfaceID.removeAll()
        terminalConfigThemesBySurfaceID.removeAll()
        runtimeSurfaceGenerationsBySurfaceID.removeAll()
    }
}
