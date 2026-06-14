import CMUXMobileCore
import CmuxTerminal
import CmuxTerminalEngine
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
        /// Per-row signatures of text *and* resolved styling, so a style-only
        /// change (e.g. typing over a dimmed shell autosuggestion) still marks
        /// the row dirty. See `MobileTerminalRenderGridFrame.rowSignatures()`.
        var rowSignatures: [String]
        /// Signature of the inherited Mac theme (palette + default
        /// fg/bg/cursor) carried on the last emitted full frame. The theme
        /// metadata only rides full snapshots, so a delta would silently drop a
        /// live theme/config change (light↔dark, edited Ghostty config) while an
        /// iPhone is attached and the terminal contents are unchanged. Forcing a
        /// full frame when this signature changes keeps the phone's palette and
        /// chrome in sync with the Mac without waiting for a cold re-attach.
        var themeSignature: String
    }

    private var releaseFrameDemand: (() -> Void)?
    private var releaseTickDemand: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pendingSurfaceIDs = Set<UUID>()
    private var hasPendingGlobalUpdate = false
    private var isEmitFlushScheduled = false
    private var renderGridStatesBySurfaceID: [UUID: RenderGridState] = [:]
    /// The Mac's resolved inherited theme, cached so the expensive config-parse +
    /// color-format work stays off the per-keystroke render path. `nil` means
    /// "not yet resolved"; recomputed lazily and invalidated whenever the parsed
    /// Ghostty config it derives from is invalidated.
    private var cachedInheritedTheme: MobileInheritedTerminalTheme?
    /// Set from any thread when the parsed Ghostty config is invalidated (app or
    /// surface-only reload). The main-actor ``inheritedTheme()`` consumes it and
    /// re-resolves. A `nonisolated` thread-safe flag (rather than the main-actor
    /// cache) so the surface-reload path can invalidate without touching the
    /// main-actor `shared` instance, which would be an actor-isolation violation
    /// from its nonisolated callers.
    nonisolated private static let themeCacheInvalidated = ThemeCacheInvalidationFlag()

    /// A tiny lock-guarded boolean so config invalidation (which can originate off
    /// the main actor) can signal the main-actor theme cache without an actor hop.
    private final class ThemeCacheInvalidationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }

        /// Returns whether the flag was set and clears it, atomically.
        func consume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            defer { value = false }
            return value
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
        // The inherited theme only changes when the Ghostty config reloads
        // (settings edit, light↔dark switch). Drop the cache then so the next
        // full frame re-resolves and the attached phone picks up the new theme;
        // the per-keystroke path never re-resolves.
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { _ in
            Self.invalidateInheritedThemeCache()
        })
        refreshNotificationDemand()
    }

    /// Drop the cached inherited theme so the next full frame re-resolves it.
    /// Called whenever the parsed Ghostty config that the theme derives from is
    /// invalidated — both the app-scoped `.ghosttyConfigDidReload` and the
    /// surface-only reload path (`GhosttyApp.reloadSurfaceConfiguration`), which
    /// invalidates `GhosttyConfig`'s load cache without posting that
    /// notification. `nonisolated` + thread-safe so either caller (some of which
    /// run off the main actor) can signal it; the next ``inheritedTheme()`` on
    /// the main actor re-resolves. Safe to call even when no phone is attached.
    nonisolated static func invalidateInheritedThemeCache() {
        themeCacheInvalidated.set()
        // Marking the cache dirty alone is not enough: an idle/background
        // terminal produces no render frames, so a theme/config change with no
        // content change would not push any new event and the attached phone
        // would keep the old palette/chrome until unrelated activity. Schedule a
        // global render-grid update so the forced full snapshot (the
        // `themeChanged` branch in `emitRenderGrid`) is actually emitted. Hops to
        // the main actor (where `shared` is isolated); no-op when no phone is
        // subscribed.
        Task { @MainActor in
            shared.scheduleThemeRefreshEmit()
        }
    }

    /// Force a global render-grid emit so a theme change with no content change
    /// still pushes a fresh full snapshot to attached phones. A Ghostty tick is
    /// scheduled too so a background workspace (which produces no frame
    /// notifications) still flushes.
    private func scheduleThemeRefreshEmit() {
        guard hasAnyRenderEventSubscribers else { return }
        enqueueTerminalUpdate(surfaceID: nil)
        GhosttyApp.shared.scheduleTick()
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
        cachedInheritedTheme = nil
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
            renderSurfaceIDs = Set(GhosttyApp.terminalSurfaceRegistry.allSurfaces().map(\.id))
        } else {
            renderSurfaceIDs = surfaceIDs
        }
        for surfaceID in renderSurfaceIDs {
            emitRenderGrid(surfaceID: surfaceID)
        }
    }

    private func emitRenderGrid(surfaceID: UUID) {
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        let theme = inheritedTheme()
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
              let snapshot = surface.mobileRenderGridFrame(
                  stateSeq: stateSeq,
                  full: true,
                  inheritedTheme: theme
              ) else {
            renderGridStatesBySurfaceID.removeValue(forKey: surfaceID)
            return
        }

        let previous = renderGridStatesBySurfaceID[surfaceID]
        let nextSignatures = snapshot.frame.rowSignatures()
        let nextThemeSignature = Self.themeSignature(of: snapshot.frame)
        let frame: MobileTerminalRenderGridFrame
        // A theme change (palette / default colors) only rides full frames, so a
        // delta or empty frame would drop it. When the resolved theme changed
        // since the last emit, send the full snapshot (which carries the new
        // theme) regardless of how few rows changed.
        let themeChanged = previous?.themeSignature != nextThemeSignature
        if let previous,
           !themeChanged,
           previous.columns == snapshot.frame.columns,
           previous.rows == snapshot.frame.rows {
            var changedRows = Set<Int>()
            let count = min(previous.rowSignatures.count, nextSignatures.count)
            for index in 0..<count where previous.rowSignatures[index] != nextSignatures[index] {
                changedRows.insert(index)
            }

            if changedRows.isEmpty {
                guard previous.stateSeq != snapshot.frame.stateSeq else { return }
                guard let emptyFrame = try? MobileTerminalRenderGridFrame(
                    surfaceID: snapshot.frame.surfaceID,
                    stateSeq: snapshot.frame.stateSeq,
                    columns: snapshot.frame.columns,
                    rows: snapshot.frame.rows,
                    cursor: snapshot.frame.cursor,
                    full: false,
                    styles: snapshot.frame.styles,
                    rowSpans: []
                ) else {
                    return
                }
                frame = emptyFrame
            } else {
                guard let deltaFrame = try? snapshot.frame.filteredRows(changedRows, full: false) else {
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
            rowSignatures: nextSignatures,
            // Track the theme from the freshly resolved snapshot (which always
            // carries it), not from `frame` (a delta nils it), so a later
            // unchanged-theme emit is correctly recognized as unchanged.
            themeSignature: nextThemeSignature
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

    /// The Mac's resolved inherited theme, resolved once and cached until the
    /// next Ghostty config reload. Keeps the config-parse + color-format work off
    /// the per-keystroke render path (every emit asks for a full snapshot before
    /// deciding delta-vs-full, so resolving per emit would tax typing latency).
    ///
    /// Shared so every full-snapshot producer — the live observer here AND the
    /// cold-attach `mobile.terminal.replay` / scroll-prefetch paths in
    /// `TerminalController` — stamps the same cached theme, so a freshly attached
    /// phone inherits it on its very first snapshot rather than waiting for a
    /// later live full event.
    func inheritedTheme() -> MobileInheritedTerminalTheme {
        // A pending invalidation (from any thread) forces a re-resolve.
        if Self.themeCacheInvalidated.consume() {
            cachedInheritedTheme = nil
        }
        if let cachedInheritedTheme {
            return cachedInheritedTheme
        }
        let resolved = TerminalSurface.resolvedTerminalTheme()
        cachedInheritedTheme = resolved
        return resolved
    }

    /// A compact signature of the inherited theme carried on a full frame. Two
    /// frames with the same signature inherit the same palette + default colors,
    /// so a delta between them is safe; a changed signature forces a full frame.
    private static func themeSignature(of frame: MobileTerminalRenderGridFrame) -> String {
        let palette = frame.terminalPalette?.joined(separator: ",") ?? "-"
        return [
            palette,
            frame.terminalForeground ?? "-",
            frame.terminalBackground ?? "-",
            frame.terminalCursorColor ?? "-",
        ].joined(separator: "|")
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
