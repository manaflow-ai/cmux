public import CmuxNextDaemon

/// A hosted Chromium page's HTML fullscreen fills its window (`BrowserTabIntent.contentFullscreen`, feature
/// `chromiumHostLocks`): no host window goes fullscreen, so the page's pane zooms, with the
/// daemon's `zoom-pane` that Toggle Pane Zoom sends, and the zoom ends when the page leaves fullscreen
/// (FULLSCREEN a = 0 after Escape or `document.exitFullscreen()`, the host's end, the tab's close or move).
/// Chrome's tab fullscreen fills the browser window the same way and gives it back on exit
/// (chrome/browser/ui/exclusive_access/fullscreen_controller.cc, `EnterFullscreenModeForTab` and
/// `ExitFullscreenModeForTab`). A pane the person had zoomed already stays zoomed after the exit.
@MainActor
public final class BrowserFullscreenPaneZoom {
    /// Sets a pane's zoom: the daemon's `zoom-pane` with mode on (true) or off, never a toggle, so a late answer
    /// never flips it. The App passes its daemon's send; tests record the calls.
    public typealias Send = @MainActor (PaneID, _ on: Bool) -> Void

    /// The pane zoomed for each page in fullscreen, and how its zoom ends.
    private var zoomed: [ObjectIdentifier: (pane: PaneID, send: Send)] = [:]

    public init() {}

    /// The pane zoomed for `page`'s fullscreen, nil when none.
    public func zoomedPane(of page: ObjectIdentifier) -> PaneID? { zoomed[page]?.pane }

    /// `page`, shown in `pane`, entered HTML fullscreen: the pane zooms, unless `store` shows it zoomed already
    /// or it is zoomed for the page.
    public func began(_ page: ObjectIdentifier, pane: PaneID, in store: DaemonStore, send: @escaping Send) {
        began(page, pane: pane, paneIsZoomed: store.workspace(containing: pane)?.screens.contains { $0.zoomedPane == pane } == true,
              send: send)
    }

    /// ``began(_:pane:in:send:)`` with the pane's zoom read already.
    public func began(_ page: ObjectIdentifier, pane: PaneID, paneIsZoomed: Bool, send: @escaping Send) {
        guard zoomed[page] == nil, !paneIsZoomed else { return }
        zoomed[page] = (pane, send)
        send(pane, true)
    }

    /// `page` left HTML fullscreen: the pane zoomed for it goes back, wherever the page is now.
    public func ended(_ page: ObjectIdentifier) {
        guard let entry = zoomed.removeValue(forKey: page) else { return }
        entry.send(entry.pane, false)
    }
}
