public import AppKit
public import CmuxNextRemoteView
import CmuxNextInputCore
import CmuxNextCompat
import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
/// The popup surfaces of one remote tab (`rb.surface.show/update/hide`,
/// RT5): each is a borderless child panel of the page's window
/// (`RemoteBrowserSurfacePanel`, page content below the app's overlays) at
/// its CSS anchor (page points are CSS
/// pixels), with its own `RemoteBrowserPane` (decoder and presenter) on its
/// own rd stream. A panel is not clipped by the page, so a popup that runs
/// past the page edge shows in full.
///
/// The panels follow the page: AppKit moves child windows with the window
/// (drags, Space changes); a page move inside the window (its rect checked
/// after each layout pass of the window while a surface is open), a window
/// resize or a screen change places them again. While the page is hidden or out of
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
    /// The page shows: surfaces decode only then (a hidden page's popups decode nothing).
    private var visible = true
    /// The page window's notices (its `WindowEvents`) and layout passes (`WindowLayoutPassHosting`), while a
    /// surface is open.
    private weak var observedWindow: NSWindow?
    private var windowObservers: [EventSubscription] = []
    /// The page window's occlusion (its `WindowOcclusionFamily`): a window seen again brings the panels back.
    private var occlusionWatch: WindowOcclusionSubscription?
    private var layoutPassWatch: WindowLayoutPasses.Observation?
    /// The page's rect in its window when the surfaces were last placed (nil: no window).
    private var placedPageRect: CGRect?
    /// How many times every surface was placed again (tests).
    package private(set) var placements = 0
    /// How many times the page's rect was read for an ancestor move (tests).
    package private(set) var placementChecks = 0
    /// The window's layout passes check the page's rect (a surface is open; tests).
    package var isCheckingPlacement: Bool { layoutPassWatch != nil }

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
            // A popup's hovers and drags are frame-aligned like the page's.
            pane.view.pointerFrames = page.pointerFrames
            pane.view.frame = CGRect(origin: .zero, size: anchor.size)
            let panel = RemoteBrowserSurfacePanel(content: pane.view)
            open[surface] = Surface(pane: pane, input: input, panel: panel, kind: kind, anchor: anchor)
            place(surface)
            if visible { pane.start() }
        case let .update(surface, anchor, _, _):
            guard open[surface] != nil else { return }
            open[surface]?.anchor = anchor
            place(surface)
        case let .hide(surface):
            remove(surface)
        }
    }

    /// The page hid or showed: each surface's decoder pauses or starts with it (Chrome stops a
    /// hidden widget's frames, `RenderWidgetHostImpl::WasHidden`). A shown surface asks for a keyframe.
    /// A hidden page's layout passes read nothing, so a page that shows places its surfaces once.
    public func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        for entry in open.values {
            if visible { entry.pane.start() } else { entry.pane.pause() }
        }
        if visible, !open.isEmpty { placeAll() }
    }

    /// The surface is decoding its stream now (tests, debug).
    package func isDecoding(_ surface: UInt32) -> Bool {
        open[surface]?.pane.isDecoding ?? false
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

    /// Sends one frame delivery of merged moves or drags at `point` to `surface` (a popup takes no wheel).
    func sendPointerFrame(_ input: PointerCoalescedInput, clickCount: Int, at point: CGPoint, surface: UInt32) {
        guard open[surface] != nil,
              let json = RemoteBrowserInputEncoder.pointer(input, clickCount: clickCount, at: point, surface: surface) else { return }
        send(json, false)
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
        placements += 1
        for surface in open.keys { place(surface) }
    }

    /// The page's rect in its window (nil: in no window).
    private var pageRectInWindow: CGRect? {
        page.window == nil ? nil : page.convert(page.bounds, to: nil)
    }

    /// The window finished a layout pass: the page may have moved inside it
    /// with nothing to tell it (an ancestor moved: a sidebar or divider drag),
    /// and its surfaces follow. A pass that moved nothing places nothing, and a
    /// hidden page reads nothing (`setVisible` places its surfaces when it shows). Chrome's
    /// `NativeViewHost` hears a change of its bounds in the root from the
    /// ancestor's bounds change (`View::RegisterForVisibleBoundsNotification`,
    /// `VisibleBoundsChanged` from `SetBoundsRect`, ui/views/view.cc), never every event.
    private func windowDidLayout() {
        guard !open.isEmpty, visible, page.window != nil else { return }
        placementChecks += 1
        guard pageRectInWindow != placedPageRect else { return }
        placeAll()
    }

    /// Shows `surface`'s panel at its anchor over the page, as a child of
    /// the page's window; orders it out while the page is not shown.
    private func place(_ surface: UInt32) {
        guard let entry = open[surface] else { return }
        let panel = entry.panel
        placedPageRect = pageRectInWindow
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

    /// Resizes, full screen and screen changes move the page inside or with
    /// the window; a window shown again brings the panels back; a closing
    /// window takes them down.
    private func observeWindow(_ window: NSWindow?) {
        // Same window and observers that match it: nothing to do. (A window
        // that went away leaves observers with a nil `observedWindow`.)
        guard !(window === observedWindow && (window == nil) == windowObservers.isEmpty) else { return }
        windowObservers.forEach { $0.cancel() }
        windowObservers.removeAll()
        occlusionWatch = nil
        layoutPassWatch?.cancel()
        layoutPassWatch = nil
        observedWindow = window
        guard let window else { return }
        let events = WindowEvents.of(window)
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didDeminiaturizeNotification] {
            windowObservers.append(events.subscribe(name, owner: "RemoteBrowserSurfaces") { [weak self] in
                self?.placeAll()
            })
        }
        occlusionWatch = WindowOcclusionFamily.of(window).subscribe(.content, owner: "RemoteBrowserSurfaces") { [weak self] _ in
            self?.placeAll()
        }
        layoutPassWatch = (window as? any WindowLayoutPassHosting)?.layoutPasses.observe(owner: "RemoteBrowserSurfaces") { [weak self] in
            self?.windowDidLayout()
        }
        windowObservers.append(events.subscribe(NSWindow.willCloseNotification, owner: "RemoteBrowserSurfaces") { [weak self] in
            guard let self else { return }
            for entry in self.open.values { self.detach(entry.panel) }
            self.observeWindow(nil)
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

    func handlePointerFrame(_ input: PointerCoalescedInput, clickCount: Int) { // perf-hot: 2us pointer-coalesce (every frame delivery to a popup)
        guard let view else { return }
        // As `handlePointer`: a hover from another window of the app comes through the screen.
        let record = input.latest
        var location = NSPoint(x: record.location.x, y: record.location.y)
        if let own = view.window, record.windowNumber != own.windowNumber {
            location = own.convertPoint(fromScreen: NSPoint(x: record.screenLocation.x, y: record.screenLocation.y))
        }
        owner?.sendPointerFrame(input, clickCount: clickCount, at: view.convert(location, from: nil), surface: surface)
    }
}
#endif
