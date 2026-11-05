import AppKit

/// Why a tab container's page windows wait for their frame at each new pane size (``CEFTabContentView/pageSyncReasons``).
nonisolated enum CEFPageSyncReason: Hashable, Sendable {
    /// A person drags a divider or edge of the pane (`dragResize` at `resizeSync`, or S5 on).
    case drag
    /// A key resize's spring moves the pane (S5 on: the page follows its pane in every frame).
    case keyResize
}

/// Page sync (fork API 27): every page window over this pane waits, up to a bounded deadline, for Chromium's frame at each
/// new pane size, so the page shows that size in the same commit as its pane (`CEFLayerHosting.paneResizeDrag`).
///
/// FRAME OWNER REFACTOR S5 (`motion.frameOwner.pages`, cmux-ad m14): in a key resize and in a divider drag the page never
/// keeps an old size (no hold, no anchored old frame). Its host view takes the pane's page area in every frame and the
/// page is hosted in the window's own layer tree (fork API 26, ``CEFLayerHosting``), so the page window's resize goes to
/// Chromium in the same turn and its frame at that size lands through the hosted context as soon as the GPU draws it.
/// The main thread never waits for it: Chromium's resize wait (`CATransactionCoordinator`) runs on its UI thread, which is
/// the main thread, so S5's deadline is `motion.frameOwner.pagesWait`, 0 by default (`CEFLayerHosting.waitMs`). Until the
/// frame comes the page shows its last frame inside its pane, unscaled; the next frame catches up.
///
/// A drag and a key resize can overlap (a key press during a drag): the shares last while either runs and end with the last.
extension CEFTabContentView {
    /// S5 is on: Chromium pages follow their pane in every frame of a key resize and of a drag. Read when each resize
    /// begins, so a flip applies from the next one and one build films both.
    static var pagesOwnedByCommit: Bool { BrowserResizeTunables.framesOwnedByCommit.value }

    /// A divider drag lays the page out live with page sync: S5 on, or `browserResize.dragResize` at `resizeSync`.
    static var syncsDragResize: Bool { pagesOwnedByCommit || BrowserResizeTunables.dragResize.value == .resizeSync }

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
