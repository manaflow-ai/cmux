import AppKit

/// Why a tab container's page windows wait for their frame at each new pane size (``CEFTabContentView/pageSyncReasons``).
nonisolated enum CEFPageSyncReason: Hashable, Sendable {
    /// A person drags a divider or edge of the pane.
    case drag
    /// A key resize's spring moves the pane: the page follows its pane in every frame.
    case keyResize
    /// A split's, close's or zoom's spring resizes the pane (``CEFTabContentView`` as ``PaneMotionTargeting``): the page
    /// follows its pane in every frame, as in a key resize.
    case paneSpring
}

/// Page sync (fork API 27): every page window over this pane waits, up to a bounded deadline, for Chromium's frame at each
/// new pane size, so the page shows that size in the same commit as its pane (`CEFLayerHosting.paneResizeDrag`).
///
/// FRAME OWNER REFACTOR S5 (cmux-ad m14, the only path since 2026-11-06): in a key resize and in a divider drag the page never
/// keeps an old size (no hold, no anchored old frame). Its host view takes the pane's page area in every frame and the
/// page is hosted in the window's own layer tree (fork API 26, ``CEFLayerHosting``), so the page window's resize goes to
/// Chromium in the same turn and its frame at that size lands through the hosted context as soon as the GPU draws it.
/// The main thread never waits for it: Chromium's resize wait (`CATransactionCoordinator`) runs on its UI thread, which is
/// the main thread, so the deadline is 0 (``CEFLayerHosting``'s default). Until the
/// frame comes the page shows its last frame inside its pane, unscaled; the next frame catches up.
///
/// A drag and a key resize can overlap (a key press during a drag): the shares last while either runs and end with the last.
extension CEFTabContentView {
    /// A resize for `reason` began: the page windows over this pane wait for their frame at each size until it ends.
    func beginPageSync(_ reason: CEFPageSyncReason) {
        pageSyncReasons.insert(reason)
        startSyncedDrag()
    }

    /// The resize for `reason` ended (a drag's release landed, a key resize's spring landed): the waits end with the last
    /// reason. An end with no begin does nothing.
    func endPageSync(_ reason: CEFPageSyncReason) {
        guard pageSyncReasons.remove(reason) != nil, pageSyncReasons.isEmpty else { return }
        endSyncedDrag()
    }

    /// The container moves to another superview in the same window (its tab moved to another pane: `BrowserPageArea.show`
    /// adds it there, so no window change is sent) or out of one: the resize of the pane it leaves is not its resize any
    /// more. Its wait shares end and its held size (a drag hold or a key hold) drops; the new pane's chrome holds it
    /// again only if that pane is in a key resize itself (`BrowserChromeView.attach`). Its page window comes back too: no
    /// end of the old pane's motion reaches it any more, and a detached window takes no click. A move into the first
    /// superview, or to the same one, keeps all.
    func leavePaneResize(for newSuperview: NSView?) {
        guard let superview, newSuperview !== superview,
              heldPageSize != nil || pageMotionHold != nil || !pageSyncReasons.isEmpty || motionHosting != nil else { return }
        dropHold()
        endAllPageSync()
        paneMotion(active: false)
    }

    /// The container left its window mid-resize: it may never hear the resize's end, so every wait ends now.
    func endAllPageSync() {
        pageSyncReasons = []
        endSyncedDrag()
    }

    /// Every page window over this pane waits for its frame at each size of the resize: the pane's shared one from
    /// every tab container (a tab switch mid-resize stays synced), a docked DevTools' only from the shown tab's (a
    /// parked tab's DevTools window draws nothing, so it would only spend the wait). Idempotent.
    func startSyncedDrag() {
        guard syncedDragHostings.isEmpty, window != nil, let tab else { return }
        syncedDragHostings = [tab.host.hostView.layerHosting]
        tab.host.hostView.layerHosting.paneResizeDrag(active: true)
        refreshSyncedDrag()
    }

    /// Keeps the shared page's share, and lends a share only to DevTools currently docked over this visible container.
    /// Reconcile before layout so newly shown DevTools waits at its first size.
    func refreshSyncedDrag() {
        guard let page = syncedDragHostings.first else { return }
        var hostings = [page]
        if !isHiddenOrHasHiddenAncestor, let host = tab?.devToolsController.views?.host, host.superview === self, !host.isHidden {
            hostings.append(host.layerHosting)
        }
        for hosting in syncedDragHostings where !hostings.contains(where: { $0 === hosting }) {
            hosting.paneResizeDrag(active: false)
        }
        for hosting in hostings where !syncedDragHostings.contains(where: { $0 === hosting }) {
            hosting.paneResizeDrag(active: true)
        }
        syncedDragHostings = hostings
    }

    /// Hands back this container's share of the page sync.
    func endSyncedDrag() {
        let hostings = syncedDragHostings
        syncedDragHostings = []
        for hosting in hostings { hosting.paneResizeDrag(active: false) }
    }
}
