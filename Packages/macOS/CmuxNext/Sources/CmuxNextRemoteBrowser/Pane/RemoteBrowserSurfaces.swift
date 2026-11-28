public import AppKit
public import CmuxNextRemoteView

#if DEBUG
/// The popup surfaces of one remote tab (`rb.surface.show/update/hide`,
/// RT5): each is a borderless child panel of the page's window
/// (`RemoteBrowserSurfacePanel`, page content below the app's overlays) at
/// its CSS anchor (page points are CSS
/// pixels), with its own `RemoteBrowserPane` (decoder and presenter) on its
/// own rd stream. A panel is not clipped by the page, so a popup that runs
/// past the page edge shows in full.
///
/// The panels follow the page: AppKit moves child windows with the window
/// (drags, Space changes); a page move inside the window (checked each
/// window update), a window resize or a screen change places them again. While the page is hidden or out of
/// a window (another tab shows, the window closes) the panels are ordered
/// out; they come back with the page. They go with the page's session.
///
/// Popup surfaces take pointer input only (cmux-remote-browser `rp_input`):
/// pointer events go out named by the surface, in its own CSS pixels; keys
/// go to the page, which routes them to the open popup.
@MainActor
public final class RemoteBrowserSurfaces {
    private let page: RemoteBrowserContentView
    private let source: @MainActor (UInt16) -> any RemoteViewStreamSource
    private let send: @MainActor (RemoteRdJSON, Bool) -> Void
    private var open: [UInt32: Surface] = [:]
    /// The page window's geometry observers, while a surface is open.
    private weak var observedWindow: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []

    /// `source` gives a surface stream's units; `send` sends one rb input
    /// event (`mustDeliver` second).
    public init(
        page: RemoteBrowserContentView, source: @escaping @MainActor (UInt16) -> any RemoteViewStreamSource,
        send: @escaping @MainActor (RemoteRdJSON, Bool) -> Void
    ) {
        self.page = page
        self.source = source
        self.send = send
        page.onPlacementChange = { [weak self] in self?.placeAll() }
    }

    /// The open surfaces, ascending.
    public var surfaceIDs: [UInt32] { open.keys.sorted() }

    public func apply(_ message: RbSurfaceMessage) {
        switch message {
        case let .show(surface, stream, kind, anchor, _, _):
            // A show of an open surface (a new size) replaces it: its stream changed.
            remove(surface)
            let pane = RemoteBrowserPane(source: source(stream))
            let input = SurfaceInput(owner: self, page: page, surface: surface)
            input.view = pane.view
            pane.view.isSurface = true
            pane.view.eventTarget = input
            pane.view.frame = CGRect(origin: .zero, size: anchor.size)
            let panel = RemoteBrowserSurfacePanel(content: pane.view)
            open[surface] = Surface(pane: pane, input: input, panel: panel, kind: kind, anchor: anchor)
            place(surface)
            pane.start()
        case let .update(surface, anchor, _, _):
            guard open[surface] != nil else { return }
            open[surface]?.anchor = anchor
            place(surface)
        case let .hide(surface):
            remove(surface)
        }
    }

    /// The session ended or closed: every surface goes.
    public func closeAll() {
        for surface in open.keys { remove(surface) }
    }

    package func view(of surface: UInt32) -> RemoteBrowserContentView? {
        open[surface]?.pane.view
    }

    /// The panel that shows `surface`.
    package func panel(of surface: UInt32) -> RemoteBrowserSurfacePanel? {
        open[surface]?.panel
    }

    /// The anchor of `surface` in the page (CSS pixels from the page's top left).
    package func anchor(of surface: UInt32) -> CGRect? {
        open[surface]?.anchor
    }

    /// The host's kind string of an open surface (`page_popup`, `autofill`,
    /// `extension_popup`, `bubble`).
    package func kind(of surface: UInt32) -> String? {
        open[surface]?.kind
    }

    /// Sends a pointer event at `point` (the surface's CSS pixels) to
    /// `surface`; dropped once the surface is gone.
    public func sendPointer(_ event: NSEvent, at point: CGPoint, surface: UInt32) {
        guard open[surface] != nil, let json = RemoteBrowserInputEncoder.pointer(event, at: point, surface: surface) else { return }
        send(json, RemoteBrowserInputEncoder.mustDeliver(event))
    }

    private func remove(_ surface: UInt32) {
        guard let gone = open.removeValue(forKey: surface) else { return }
        gone.pane.stop()
        detach(gone.panel)
        gone.panel.close()
        if open.isEmpty { observeWindow(nil) }
    }

    /// Every open surface at its anchor (the page moved, resized, was
    /// hidden or shown, or changed window).
    private func placeAll() {
        for surface in open.keys { place(surface) }
    }

    /// Shows `surface`'s panel at its anchor over the page, as a child of
    /// the page's window; orders it out while the page is not shown.
    private func place(_ surface: UInt32) {
        guard let entry = open[surface] else { return }
        let panel = entry.panel
        // Observe the window while it is the page's, also while it is not
        // visible (minimized, ordered out): its return places the panel.
        observeWindow(page.window)
        guard let window = page.window, window.isVisible, !page.isHiddenOrHasHiddenAncestor else {
            detach(panel)
            return
        }
        // The page is flipped: the anchor's origin is its top left, as in CSS.
        let frame = window.convertToScreen(page.convert(entry.anchor, to: nil))
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            // A child window orders in with its parent (above it) and never
            // activates the app or becomes key. The main window's
            // addChildWindow puts the overlay host back above it.
            window.addChildWindow(panel, ordered: .above)
        }
    }

    private func detach(_ panel: RemoteBrowserSurfacePanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Window updates (a page move inside the window), resizes, full screen
    /// and screen changes move the page inside or with the window; a window
    /// shown again brings the panels back; a closing window takes them down.
    private func observeWindow(_ window: NSWindow?) {
        // Same window and observers that match it: nothing to do. (A window
        // that went away leaves observers with a nil `observedWindow`.)
        guard !(window === observedWindow && (window == nil) == windowObservers.isEmpty) else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // main-proof: observer on queue: .main
                MainActor.assumeIsolated { self?.placeAll() }
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // main-proof: observer on queue: .main
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in self.open.values { self.detach(entry.panel) }
                self.observeWindow(nil)
            }
        })
    }

    private struct Surface {
        let pane: RemoteBrowserPane
        let input: SurfaceInput
        let panel: RemoteBrowserSurfacePanel
        let kind: String
        var anchor: CGRect
    }
}

/// One surface view's events: pointers to the surface, keys to the page.
@MainActor
private final class SurfaceInput: RemoteBrowserEventTarget {
    private weak var owner: RemoteBrowserSurfaces?
    private weak var page: RemoteBrowserContentView?
    weak var view: RemoteBrowserContentView?
    private let surface: UInt32

    init(owner: RemoteBrowserSurfaces, page: RemoteBrowserContentView, surface: UInt32) {
        self.owner = owner
        self.page = page
        self.surface = surface
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        page?.eventTarget?.handleKeyEquivalent(event) ?? false
    }

    func handleKey(_ event: NSEvent) {
        page?.eventTarget?.handleKey(event)
    }

    func handlePointer(_ event: NSEvent) {
        guard let view else { return }
        // A hover event can come from another window of the app: through the screen.
        var location = event.locationInWindow
        if let from = event.window, let own = view.window, from !== own {
            location = own.convertPoint(fromScreen: from.convertPoint(toScreen: location))
        }
        owner?.sendPointer(event, at: view.convert(location, from: nil), surface: surface)
    }
}
#endif
