import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif


private var cmuxWindowTerminalPortalKey: UInt8 = 0
private var cmuxWindowTerminalPortalCloseObserverKey: UInt8 = 0

@MainActor
enum TerminalWindowPortalRegistry {
#if DEBUG
    static var isPointerDragActiveForTesting = false
#endif
    private static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var hasPendingExternalGeometrySyncForAllWindows = false
    private static var externalGeometrySyncForAllWindowsGeneration: UInt64 = 0
    private static var interactiveGeometryResizeCount = 0
    private static var activeSplitDividerDragWindowId: ObjectIdentifier?
    private static var activeSplitDividerDragEventNumber: Int?
#if DEBUG
    private static var blockedBindCount: Int = 0
    private static var blockedBindReasons: [String: Int] = [:]
#endif

    static var isInteractiveGeometryResizeActive: Bool {
#if DEBUG
        if Self.isPointerDragActiveForTesting { return true }
#endif
        if Self.interactiveGeometryResizeCount > 0 { return true }
        return isCurrentEventSplitDividerDrag()
    }

    private static func isCurrentEventSplitDividerDrag() -> Bool {
        let isLeftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard isLeftButtonDown else {
            clearActiveSplitDividerDrag()
            return false
        }

        guard let event = NSApp.currentEvent else { return false }

        switch event.type {
        case .leftMouseUp:
            clearActiveSplitDividerDrag()
            return false
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return false
        }

        if let activeSplitDividerDragWindowId, let activeSplitDividerDragEventNumber {
            let hasActiveWindow = NSApp.windows.contains { ObjectIdentifier($0) == activeSplitDividerDragWindowId }
            if hasActiveWindow, event.eventNumber == activeSplitDividerDragEventNumber {
                return true
            }
            clearActiveSplitDividerDrag()
        }

        guard event.type == .leftMouseDown else { return false }

        let candidateWindows = currentSplitDividerDragCandidateWindows(for: event)
        let mouseLocation = NSEvent.mouseLocation
        for window in candidateWindows {
            if WindowTerminalHostView.hasSplitDivider(atScreenPoint: mouseLocation, in: window) {
                activeSplitDividerDragWindowId = ObjectIdentifier(window)
                activeSplitDividerDragEventNumber = event.eventNumber
                return true
            }
        }

        return false
    }

    private static func clearActiveSplitDividerDrag() {
        activeSplitDividerDragWindowId = nil
        activeSplitDividerDragEventNumber = nil
    }

    static func noteSplitDividerInteraction(in window: NSWindow?, event: NSEvent?) {
        guard let window, let event else { return }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }

        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            activeSplitDividerDragWindowId = ObjectIdentifier(window)
            activeSplitDividerDragEventNumber = event.eventNumber
        default:
            break
        }
    }

    private static func currentSplitDividerDragCandidateWindows(for event: NSEvent) -> [NSWindow] {
        var candidateWindows: [NSWindow] = []
        if let eventWindow = event.window {
            candidateWindows.append(eventWindow)
        }
        if let keyWindow = NSApp.keyWindow, !candidateWindows.contains(where: { $0 === keyWindow }) {
            candidateWindows.append(keyWindow)
        }
        if let mainWindow = NSApp.mainWindow, !candidateWindows.contains(where: { $0 === mainWindow }) {
            candidateWindows.append(mainWindow)
        }
        return candidateWindows
    }

    private static func bindBlockReason(
        expectedSurfaceId: UUID?,
        expectedGeneration: UInt64?,
        actual: (surfaceId: UUID?, generation: UInt64?, state: String)
    ) -> String {
        if actual.surfaceId == nil {
            return "missingSurface"
        }
        if actual.state != "live" {
            return "state_\(actual.state)"
        }
        if let expectedSurfaceId, actual.surfaceId != expectedSurfaceId {
            return "surfaceMismatch"
        }
        if let expectedGeneration, actual.generation != expectedGeneration {
            return "generationMismatch"
        }
        return "guardRejected"
    }

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &cmuxWindowTerminalPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneHostedMappings(for windowId: ObjectIdentifier, validHostedIds: Set<ObjectIdentifier>) {
        hostedToWindowId = hostedToWindowId.filter { hostedId, mappedWindowId in
            mappedWindowId != windowId || validHostedIds.contains(hostedId)
        }
    }

    private static func portal(for window: NSWindow, syncLayout: Bool = true) -> WindowTerminalPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowTerminalPortal(window: window, syncLayout: syncLayout)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    private static func existingPortal(for window: NSWindow) -> WindowTerminalPortal? {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }
        return portalsByWindowId[ObjectIdentifier(window)]
    }

    static func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        expectedSurfaceId: UUID? = nil,
        expectedGeneration: UInt64? = nil,
        deferLayoutSynchronization: Bool = false
    ) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)
        let guardState = hostedView.portalBindingGuardState()
        guard hostedView.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        ) else {
            if let oldWindowId = hostedToWindowId.removeValue(forKey: hostedId) {
                portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
            }
#if DEBUG
            let reason = bindBlockReason(
                expectedSurfaceId: expectedSurfaceId,
                expectedGeneration: expectedGeneration,
                actual: guardState
            )
            blockedBindCount += 1
            blockedBindReasons[reason, default: 0] += 1
            cmuxDebugLog(
                "portal.bind.blocked hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(reason) expectedSurface=\(expectedSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                "expectedGeneration=\(expectedGeneration.map { String($0) } ?? "nil") " +
                "actualSurface=\(guardState.surfaceId?.uuidString.prefix(5) ?? "nil") " +
                "actualGeneration=\(guardState.generation.map { String($0) } ?? "nil") " +
                "actualState=\(guardState.state)"
            )
#endif
            return
        }

        let nextPortal = portal(for: window, syncLayout: !deferLayoutSynchronization)

        if let oldWindowId = hostedToWindowId[hostedId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
        }

        nextPortal.bind(
            hostedView: hostedView,
            to: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            deferLayoutSynchronization: deferLayoutSynchronization
        )
        hostedToWindowId[hostedId] = windowId
        pruneHostedMappings(for: windowId, validHostedIds: nextPortal.hostedIds())
    }

    static func synchronizeForAnchor(_ anchorView: NSView, syncLayout: Bool = true) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window, syncLayout: syncLayout)
        portal.synchronizeHostedViewForAnchor(anchorView, syncLayout: syncLayout)
    }

    static func scheduleExternalGeometrySynchronize(for window: NSWindow, forceImmediate: Bool = true) {
        existingPortal(for: window)?.scheduleExternalGeometrySynchronize(forceImmediate: forceImmediate)
    }

#if DEBUG
    static func synchronizeExternalGeometryNow(for window: NSWindow) {
        existingPortal(for: window)?.synchronizeAllEntriesFromExternalGeometryChange()
    }
#endif

    static func beginInteractiveGeometryResize() {
        interactiveGeometryResizeCount += 1
    }

    static func endInteractiveGeometryResize() {
        interactiveGeometryResizeCount = max(0, interactiveGeometryResizeCount - 1)
    }

    static func scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: Bool = true) {
        // Same latest-request-wins coalescing for callers that don't have a
        // concrete window handle yet.
        Self.externalGeometrySyncForAllWindowsGeneration &+= 1
        let generation = Self.externalGeometrySyncForAllWindowsGeneration
        guard !Self.hasPendingExternalGeometrySyncForAllWindows else { return }
        Self.hasPendingExternalGeometrySyncForAllWindows = true
        let isDragEvent = forceImmediate || Self.isInteractiveGeometryResizeActive
        DispatchQueue.main.async {
            let performSync = {
                var shouldFlushLatestNow = isDragEvent
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = Self.isInteractiveGeometryResizeActive
                }
                if Self.externalGeometrySyncForAllWindowsGeneration != generation, !shouldFlushLatestNow {
                    Self.hasPendingExternalGeometrySyncForAllWindows = false
                    Self.scheduleExternalGeometrySynchronizeForAllWindows(forceImmediate: forceImmediate)
                    return
                }
                Self.hasPendingExternalGeometrySyncForAllWindows = false
                for portal in Self.portalsByWindowId.values {
                    portal.synchronizeAllEntriesFromExternalGeometryChange()
                }
            }
            var shouldPerformNow = isDragEvent
            if !shouldPerformNow {
                shouldPerformNow = Self.isInteractiveGeometryResizeActive
            }
            if shouldPerformNow {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    static func hideHostedView(_ hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideEntry(forHostedId: hostedId)
    }

    /// Permanently detach a hosted terminal view from the window-level portal.
    /// Use this when a terminal panel is actually closing (not transient SwiftUI dismantle).
    static func detach(hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId.removeValue(forKey: hostedId) else { return }
        portalsByWindowId[windowId]?.detachHostedView(withId: hostedId)
    }

    /// Update the visibleInUI flag on an existing portal entry without rebinding.
    /// Called when a bind is deferred (host not yet in window) to prevent stale
    /// portal syncs from hiding a view that is about to become visible.
    static func updateEntryVisibility(for hostedView: GhosttySurfaceScrollView, visibleInUI: Bool) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let windowId = hostedToWindowId[hostedId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: visibleInUI)
    }

    static func isHostedView(_ hostedView: GhosttySurfaceScrollView, boundTo anchorView: NSView) -> Bool {
        let hostedId = ObjectIdentifier(hostedView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard hostedToWindowId[hostedId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
        return portal.isHostedViewBoundToAnchor(withId: hostedId, anchorView: anchorView)
    }

    static func viewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        let portal = portal(for: window)
        return portal.viewAtWindowPoint(windowPoint)
    }

    static func terminalViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> GhosttyNSView? {
        let portal = portal(for: window)
        return portal.terminalViewAtWindowPoint(windowPoint)
    }

    static func terminalPaneDropTargetAtWindowPoint(
        _ windowPoint: NSPoint,
        in window: NSWindow
    ) -> TerminalPaneDropTargetView? {
        let portal = portal(for: window)
        return portal.terminalPaneDropTargetAtWindowPoint(windowPoint)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }

    static func debugPortalStats() -> [String: Any] {
        var portals: [[String: Any]] = []
        var totals: [String: Int] = [
            "entry_count": 0,
            "host_subview_count": 0,
            "terminal_subview_count": 0,
            "mapped_terminal_subview_count": 0,
            "orphan_terminal_subview_count": 0,
            "visible_orphan_terminal_subview_count": 0,
            "stale_entry_count": 0,
            "visible_invalid_anchor_entry_count": 0,
            "mapped_hosted_count": 0,
        ]

        for (windowId, portal) in portalsByWindowId {
            let stats = portal.debugStats()
            let mappedHostedCount = hostedToWindowId.values.reduce(0) { partialResult, mappedWindowId in
                partialResult + (mappedWindowId == windowId ? 1 : 0)
            }
            let integrityOK =
                stats.orphanTerminalSubviewCount == 0 &&
                stats.visibleOrphanTerminalSubviewCount == 0 &&
                stats.staleEntryCount == 0 &&
                stats.visibleInvalidAnchorEntryCount == 0 &&
                mappedHostedCount == stats.entryCount

            portals.append([
                "window_number": stats.windowNumber,
                "entry_count": stats.entryCount,
                "mapped_hosted_count": mappedHostedCount,
                "host_subview_count": stats.hostSubviewCount,
                "terminal_subview_count": stats.terminalSubviewCount,
                "mapped_terminal_subview_count": stats.mappedTerminalSubviewCount,
                "orphan_terminal_subview_count": stats.orphanTerminalSubviewCount,
                "visible_orphan_terminal_subview_count": stats.visibleOrphanTerminalSubviewCount,
                "stale_entry_count": stats.staleEntryCount,
                "visible_invalid_anchor_entry_count": stats.visibleInvalidAnchorEntryCount,
                "integrity_ok": integrityOK,
            ])

            totals["entry_count", default: 0] += stats.entryCount
            totals["host_subview_count", default: 0] += stats.hostSubviewCount
            totals["terminal_subview_count", default: 0] += stats.terminalSubviewCount
            totals["mapped_terminal_subview_count", default: 0] += stats.mappedTerminalSubviewCount
            totals["orphan_terminal_subview_count", default: 0] += stats.orphanTerminalSubviewCount
            totals["visible_orphan_terminal_subview_count", default: 0] += stats.visibleOrphanTerminalSubviewCount
            totals["stale_entry_count", default: 0] += stats.staleEntryCount
            totals["visible_invalid_anchor_entry_count", default: 0] += stats.visibleInvalidAnchorEntryCount
            totals["mapped_hosted_count", default: 0] += mappedHostedCount
        }

        portals.sort {
            let lhs = ($0["window_number"] as? Int) ?? Int.min
            let rhs = ($1["window_number"] as? Int) ?? Int.min
            return lhs < rhs
        }

        return [
            "portal_count": portals.count,
            "hosted_mapping_count": hostedToWindowId.count,
            "guarded_bind_blocked_count": blockedBindCount,
            "guarded_bind_blocked_reasons": blockedBindReasons,
            "portals": portals,
            "totals": totals,
        ]
    }
#endif
}
