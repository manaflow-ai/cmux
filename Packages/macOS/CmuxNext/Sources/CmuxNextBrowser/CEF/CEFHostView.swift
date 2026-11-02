import AppKit
import CmuxNextDesign

/// The parent view of a pane's Chromium window. The fork's
/// `CmuxParentViewTracker` keeps the page window over this view, clips it to
/// the visible rect, and punches holes where `cmuxOcclusionRects` says native
/// UI must show above the page (find bar, prompt bar) or must get the mouse
/// (the window's dividers and switcher, `BrowserWindowOcclusionProviding`),
/// and masks it to `cmuxClipPath` (rounded pane and window corners).
final class CEFHostView: NSView {
    /// Rects in this view's coordinates where native UI covers the page.
    var occlusionRects: [CGRect] = [] {
        didSet {
            guard occlusionRects != oldValue else { return }
            postGeometryChange()
        }
    }
    /// Rounded native UI over the page (the prompt and find bars), in this
    /// view's coordinates. They leave the clip path (`cmuxClipPath`) with their
    /// corners, so the page shows around a rounded bar's corners instead of a
    /// square hole of pane ground, and the mouse inside them goes to the bar.
    var roundedOcclusions: [CEFClipShape.RoundedRect] = [] {
        didSet {
            guard roundedOcclusions != oldValue else { return }
            postGeometryChange()
        }
    }
    private var windowObserver: (any NSObjectProtocol)?
    /// The shown page's own background (`CEFTab.pageBackdropColor`). While
    /// the window live-resizes, this view fills with it instead of the pane
    /// ground: the page window's gap shows this view until Chromium's frame
    /// at the new size arrives (`CEFTab+ResizeBackdrop`).
    var pageBackdrop: CGColor? {
        didSet { if pageBackdrop != oldValue { updateBackground() } }
    }
    /// The shown page is see-through (a cmux page, `CEFTab.pageSeeThrough`): this view under it
    /// paints nothing, so the pane and the window backdrop show as under a WebKit page.
    var pageSeeThrough = false {
        didSet { if pageSeeThrough != oldValue { updateBackground() } }
    }

    /// Called when the window starts a live resize (`CEFPaneHost` re-reads
    /// the shown page's background).
    var liveResizeWillStart: (() -> Void)?
    /// Hands files dragged in from another app to the shown page (`CEFFileDragRelay`).
    let fileDrag = CEFFileDragRelay()
    /// Layer hosting (fork API 26) of the page window over this view (`CEFLayerHosting`).
    let layerHosting = CEFLayerHosting()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateBackground()
        fileDrag.view = self
        layerHosting.view = self
        #if DEBUG || CMUX_BENCH_HOOKS
        Self.registerMotionSampler()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Presses on the page area

    /// A press reaches this view only where the page window takes no mouse: the whole page before a
    /// tab's first real page (the New Tab page, a blank page), which is cut out of the page window
    /// (`CEFTab.applyOcclusion`). Chromium focuses the web contents on such a press, and the omnibox
    /// blurs (`OmniboxViewViews::OnBlur`), so the press makes this view first responder: an edit in
    /// the omnibar ends there (its typed text stays), and the focus model reads the responder as the
    /// pane's page (`FocusResponderClassifier`) and gives the page the keyboard, as a press inside
    /// the page window does (Lawrence 2026-10-30: "i click outside and omnibar is still focused").
    override var acceptsFirstResponder: Bool { true }
    /// Not a stop of the keyboard loop: only a press focuses the page this way.
    override var canBecomeKeyView: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { focusPageOnPress() }
    override func rightMouseDown(with event: NSEvent) {
        focusPageOnPress()
        super.rightMouseDown(with: event)
    }
    override func otherMouseDown(with event: NSEvent) { focusPageOnPress() }

    private func focusPageOnPress() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeWillStart?()
        layerHosting.windowLiveResize(active: true)
        updateBackground()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layerHosting.windowLiveResize(active: false)
        updateBackground()
    }

    /// Until Chromium's page window shows its first frame, the page area
    /// follows the shared pane ground. It stays clear over Liquid Glass so
    /// the window backdrop remains visible. During a live resize it takes
    /// the page's own background (`pageBackdrop`). Under a see-through page
    /// (`pageSeeThrough`) it paints nothing, so the page shows what a WebKit
    /// page shows.
    private func updateBackground() {
        if pageSeeThrough {
            layer?.backgroundColor = nil
            return
        }
        if inLiveResize, let pageBackdrop {
            layer?.backgroundColor = pageBackdrop
            return
        }
        performWithTheme {
            layer?.backgroundColor = Palette.paneFill.cgColor
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        }
    }

    /// Read by the fork (`-cmuxOcclusionRects`, NSArray of NSValue NSRect)
    /// on every geometry update, so window rects convert at the current
    /// position.
    @objc func cmuxOcclusionRects() -> NSArray {
        Self.trackerStats.occlusionReads += 1
        // The fork reads these first on every update of a shown page.
        let geometry = CEFHostGeometry(of: self)
        readGeometry = geometry
        return occlusionMemoValue(for: geometry).bridged
    }

    /// Read by the fork (`-cmuxClipPath`) on every geometry update: the
    /// pane's rounded clip and the window's rounded corners, so no square
    /// page corner shows past either. Nil when the page is a plain rect.
    /// The same path object comes back until the shape changes; the fork
    /// only reads it (it maps a copy to screen coordinates).
    @objc func cmuxClipPath() -> NSBezierPath? {
        Self.trackerStats.clipReads += 1
        layerHosting.trackerDidRead()
        return clipShape().bezier
    }

    /// The pane's rounded clip, the column strip's clip and the window's corners, in this view.
    var pageClip: CGPath? { clipShape().path }

    /// The last clip shape and what it was worked out from. The fork reads
    /// the clip and the occlusion rects on every geometry update, several
    /// times per display frame while a pane moves, and also on window moves,
    /// key changes and occlusion changes that move nothing. The path
    /// operations run only when the bounds, a clip or a cutout changed; the
    /// walk of the ancestors that finds those still runs on every read.
    private var clipMemo: ClipMemo?

    private struct ClipMemo {
        let inputs: CEFClipShape.Inputs
        let path: CGPath?
        /// `path` for the fork; nil when the page is a plain rect, and when it
        /// shows nothing: a page clipped away entirely is hidden by an occlusion
        /// hole over all of it (`allOcclusionRects`), the fork's documented way
        /// to keep a page from showing.
        let bezier: NSBezierPath?
    }

    /// The fork asks for the same occlusion array several times while a page
    /// settles. Keep both the normalized rectangles and their Objective-C
    /// bridge for the geometry they were worked out from: the host's bounds,
    /// its ancestors' clips and cutouts, its own holes and the window's
    /// overlays over it (`CEFHostGeometry`, read anyway on every fork read).
    /// A frame or ancestor change AppKit reports to the fork directly, with
    /// no `postGeometryChange`, still gives a different key and a fresh build.
    private struct OcclusionMemo {
        let geometry: CEFHostGeometry
        let rects: [CGRect]
        let bridged: NSArray
    }

    private var occlusionMemo: OcclusionMemo?

    private func clipShape() -> ClipMemo {
        let started = CEFTrackerStats.now()
        defer { Self.trackerStats.clipSeconds += CEFTrackerStats.now() - started }
        let inputs = CEFClipShape.Inputs(around: self)
        if let clipMemo, clipMemo.inputs == inputs {
            Self.trackerStats.clipHits += 1
            return clipMemo
        }
        Self.trackerStats.clipBuilds += 1
        let path = inputs.path
        let bezier = CEFClipShape.showsNothing(path) ? nil : path.map { NSBezierPath(cgPath: $0) }
        let memo = ClipMemo(inputs: inputs, path: path, bezier: bezier)
        clipMemo = memo
        return memo
    }

    /// The chrome's rects plus the window's interactive overlays over this
    /// view, in this view's coordinates.
    var allOcclusionRects: [CGRect] {
        occlusionMemoValue(for: CEFHostGeometry(of: self)).rects
    }

    private func occlusionMemoValue(for geometry: CEFHostGeometry) -> OcclusionMemo {
        if let memo = occlusionMemo, memo.geometry == geometry {
            Self.trackerStats.occlusionHits += 1
            return memo
        }
        let started = CEFTrackerStats.now()
        defer { Self.trackerStats.occlusionSeconds += CEFTrackerStats.now() - started }
        Self.trackerStats.occlusionBuilds += 1
        let rects: [CGRect]
        if CEFClipShape.showsNothing(pageClip), !bounds.isEmpty {
            rects = [bounds]
        } else {
            var normalized = occlusionRects
            if let provider = window as? any BrowserWindowOcclusionProviding {
                for rect in provider.browserOcclusionRectsInWindow {
                    let local = convert(rect, from: nil).intersection(bounds)
                    if !local.isNull, !local.isEmpty { normalized.append(local) }
                }
            }
            rects = Self.outermost(normalized)
        }
        let memo = OcclusionMemo(geometry: geometry, rects: rects, bridged: rects.map { NSValue(rect: $0) } as NSArray)
        occlusionMemo = memo
        return memo
    }

    /// `rects` without those inside another (one of equal rects stays): a
    /// hole inside a hole, such as the error page's in the New Tab page's,
    /// would cancel it in an even-odd mask and show the page there again.
    static func outermost(_ rects: [CGRect]) -> [CGRect] {
        rects.enumerated().filter { index, rect in
            !rects.enumerated().contains { other, outer in
                other != index && outer.contains(rect) && (outer != rect || other < index)
            }
        }.map(\.element)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        readGeometry = nil
        invalidateOcclusionMemo()
        // A resize-wait tunable edit made while out of a window applies (CEFResizeSyncDeadline).
        layerHosting.windowDidChange()
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: Notification.Name.browserChildWindowPagesNeedUpdate, object: window, queue: .main) { [weak self] note in
            let force = note.userInfo?[browserPagesForceUpdateKey] as? Bool ?? false
            MainActor.assumeIsolated { self?.pagesNeedUpdate(force: force) } // main-proof: observer on queue: .main
        }
    }

    /// What the fork read on its last update of this page (`cmuxOcclusionRects`);
    /// nil before its first read and after a window change.
    private var readGeometry: CEFHostGeometry?

    /// The window asks its pages to re-apply their geometry (the divider lines
    /// or the sidebar moved, a clip or corner changed, the window moved). The
    /// fork is told only when what it reads changed since its last read: on a
    /// motion frame the static pages have nothing to re-place, re-clip or
    /// re-mask (Lawrence 2026-10-23: splits lag more with Chromium pages).
    /// `force`: a page window moved by something other than the fork must be
    /// put back over its host even though the host did not move.
    func pagesNeedUpdate(force: Bool) {
        let now = CEFHostGeometry(of: self)
        guard force || readGeometry != now else {
            Self.trackerStats.geometrySkips += 1
            return
        }
        postGeometryChange()
        // The fork updates inside the post; a hidden or not yet created page reads nothing
        // there, so what it was told is recorded here (a still hidden page has nothing new).
        readGeometry = now
    }

    /// Tells the tracker about moves AppKit does not report (layer
    /// transforms, manual frame animation in an ancestor).
    func postGeometryChange() { // perf-hot: 0.2ms cef-geometry (each post makes the fork re-place one page window)
        invalidateOcclusionMemo()
        Self.trackerStats.geometryPosts += 1
        NotificationCenter.default.post(name: CEFHostView.geometryDidChange, object: self)
    }

    private func invalidateOcclusionMemo() {
        occlusionMemo = nil
    }

    /// What the fork's tracker read from host views so far (`debug.cef` `tracker`).
    static var trackerStats = CEFTrackerStats()

    /// `CmuxParentViewGeometryDidChange` in the fork.
    static let geometryDidChange = Notification.Name("CmuxParentViewGeometryDidChange")
}

/// A CEF tab's `contentView`. All tabs of a pane share one Chromium window,
/// so the container only borrows the pane's `CEFHostView` while it is in a
/// window, and shows a snapshot while the tab is occluded.
final class CEFTabContentView: NSView, PaneMotionSettling, PaneResizeGestureFollowing {
    weak var tab: CEFTab?
    private let snapshotView = NSImageView()
    /// The page's size through a person's resize drag (`paneResizeGestureDidChange`); nil otherwise.
    private(set) var heldPageSize: CGSize?
    /// The page windows told of a resize-sync drag (`BrowserDragResize.resizeSync`), to tell its end wherever the
    /// page is by then; empty otherwise.
    private(set) var syncedDragHostings: [CEFLayerHosting] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Not flipped, like CEFHostView, so occlusion rects in this view's
    // coordinates are also valid in the host view that fills it.

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tab?.pageThemeDidChange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tab?.deviceEmulationViewDidResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dropHold()
            // A container leaving the window (its tab closed or moved mid-drag) may never hear the drag's end.
            endSyncedDrag()
        }
        guard let tab else { return }
        tab.pageThemeDidChange()
        // A tab parked hidden in its pane (PaneContentView+Parking) shows
        // when it is unhidden, not when it enters the window.
        if window != nil, !isHiddenOrHasHiddenAncestor {
            tab.contentDidAppear(in: self)
        } else {
            tab.contentDidDisappear()
        }
    }

    /// The pane parked this tab (another tab of the pane shows): it lets the
    /// shared host view go, as when it leaves the window, at no window move.
    override func viewDidHide() {
        super.viewDidHide()
        dropHold()
        refreshSyncedDrag()
        tab?.contentDidDisappear()
    }

    /// The pane shows this parked tab again: it takes the host view.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard let tab, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        refreshSyncedDrag()
        tab.pageThemeDidChange()
        tab.contentDidAppear(in: self)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    /// The page (the pane's shared `CEFHostView` and the snapshot) takes
    /// the page frame; a docked DevTools and its divider take the rest.
    func layoutContent() {
        // DevTools can open, close or change dock while the drag is already active.
        refreshSyncedDrag()
        // DevTools docked, a side panel or a device fit came up mid-drag: they lay out as before.
        if heldPageSize != nil, !pageCanHold { dropHold() }
        let frames = tab?.devToolsController.frames(in: bounds)
            ?? CEFDevToolsLayout.Frames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        let devToolsHost = tab?.devToolsController.views?.host
        // A fit (cx-qby5j) shows the page in its presented rect inside the frame view.
        let emulation = tab?.deviceEmulation
        // The frame stays under the host view (the pane host is re-added at the bottom on a tab switch).
        if let frame = subviews.first(where: { $0 is BrowserFitFrameView }), subviews.first !== frame {
            addSubview(frame, positioned: .below, relativeTo: nil)
        }
        // With a side panel, Chromium's window holds the panel and the page, so the host keeps the page frame.
        // DevTools device mode places the page itself (the fit yields until it ends).
        // In a DevTools window the page keeps its full frame, but the fit still yields.
        let deviceMode = tab?.devToolsController.deviceModeOn ?? false
        let fitPage = tab?.sidePanel.state == nil && !deviceMode ? emulation?.presentedRect(in: pageViewportFrame) : nil
        for subview in subviews {
            let frame: CGRect
            if let fitFrame = subview as? BrowserFitFrameView {
                frame = pageViewportFrame
                if let fitPage, let viewport = emulation.flatMap({ $0.viewport(in: $0.layoutArea(in: pageViewportFrame).size) }) {
                    let presented = fitPage.offsetBy(dx: -frame.minX, dy: -frame.minY)
                    fitFrame.update(emulation: emulation, presented: presented, layout: viewport.size, scale: viewport.scale)
                }
            } else if subview is SidePanelHeaderView {
                frame = tab?.sidePanel.headerFrame ?? .zero
            } else if subview === devToolsHost {
                frame = frames.devTools
            } else if subview is CEFDevToolsDivider {
                frame = frames.grab
            } else if fitPage == nil, let held = heldPageSize, subview === tab?.host.hostView {
                // A resize drag: the page keeps its size at the page frame's top-left corner, and the
                // pane clips it (`CEFClipShape` and the fork's visible rect read the held host).
                frame = CGRect(x: frames.page.minX, y: frames.page.maxY - held.height, width: held.width, height: held.height)
            } else {
                frame = fitPage ?? frames.page
            }
            if subview.frame != frame { subview.frame = frame }
        }
        tab?.applyOcclusion()
        // DevTools or the side panel moved the page area without a resize of this view: refit.
        if let tab, let emulation, !deviceMode, emulation.viewport(in: emulation.layoutArea(in: pageViewportFrame).size) != tab.deviceEmulationViewport {
            tab.applyDeviceEmulation()
        }
    }

    /// The pane's layout spring landed (a split's new pane grown in, a close, a zoom): the shown
    /// page is placed and clipped at the landed frame (`CEFPaneHost.paneMotionSettled`).
    func paneMotionDidSettle() {
        guard let tab, tab.host.hostView.superview === self else { return }
        tab.host.paneMotionSettled(tab)
    }

    /// A person's divider or edge drag began or landed (`ScreenContentView+ResizeGesture`). Chromium
    /// draws the page in another process, some frames after its window takes a size, so a page laid
    /// out at every drag frame trails the divider and catches up in steps. Through the drag the page
    /// keeps the size it had when the drag began: its window moves with the pane in the pane's own
    /// frame, the pane clips it (top-left anchored, never stretched), and a pane grown past it shows
    /// the page's own background beside it. It lays out once when the drag lands. Only a plain page
    /// holds: a docked DevTools, a side panel or a device fit lay out as before.
    ///
    /// With `dragResize` at `resizeSync` (fork API 27) the page lays out live instead, and each page window over
    /// the pane (the page's, a docked DevTools') holds every app frame of the drag and its landing for its frame at
    /// the new size, up to a bounded deadline (`CEFLayerHosting.paneResizeDrag`).
    func paneResizeGestureDidChange(active: Bool) {
        guard active else {
            endSyncedDrag()
            guard heldPageSize != nil else { return }
            dropHold()
            layoutContent()
            return
        }
        if BrowserResizeTunables.dragResize.value == .resizeSync {
            startSyncedDrag()
            return
        }
        guard BrowserResizeTunables.dragResize.value == .hold, heldPageSize == nil, window != nil, pageCanHold,
              let tab else { return }
        let size = tab.host.hostView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        heldPageSize = size
        // The held page is cut at this view's edges: its layer here, and the page window by the
        // fork's visible rect, which follows every ancestor whose layer masks to its bounds.
        layer?.masksToBounds = true
        // A see-through page (a cmux page) shows the pane under it, so its gap does too.
        layer?.backgroundColor = tab.host.hostView.pageSeeThrough ? nil : tab.pageBackdropColor
    }

    /// Every page window over this pane waits for its frame at each size of the drag: the pane's shared one from
    /// every tab container (a tab switch mid-drag stays synced), a docked DevTools' only from the shown tab's (a
    /// parked tab's DevTools window draws nothing, so it would only spend the wait).
    private func startSyncedDrag() {
        guard syncedDragHostings.isEmpty, window != nil, let tab else { return }
        syncedDragHostings = [tab.host.hostView.layerHosting]
        tab.host.hostView.layerHosting.paneResizeDrag(active: true)
        refreshSyncedDrag()
    }

    /// Keeps the shared page's drag share, and lends a share only to DevTools currently docked over
    /// this visible container. Reconcile before layout so newly shown DevTools waits at its first size.
    private func refreshSyncedDrag() {
        guard let page = syncedDragHostings.first else { return }
        var hostings = [page]
        if !isHiddenOrHasHiddenAncestor, let host = tab?.devToolsController.views?.host, host.superview === self {
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

    /// Hands back this container's share of a resize-sync drag.
    private func endSyncedDrag() {
        let hostings = syncedDragHostings
        syncedDragHostings = []
        for hosting in hostings { hosting.paneResizeDrag(active: false) }
    }

    /// A plain page shown here: no docked DevTools, side panel or device fit, which place the page themselves.
    private var pageCanHold: Bool {
        guard let tab else { return false }
        return tab.host.hostView.superview === self && tab.devToolsController.views == nil
            && tab.sidePanel.state == nil && tab.deviceEmulation == nil
    }

    /// Lets go of a held page size; the next layout gives the page its frame.
    private func dropHold() {
        guard heldPageSize != nil else { return }
        heldPageSize = nil
        layer?.masksToBounds = false
        layer?.backgroundColor = nil
        needsLayout = true
    }

    /// Adds the fit frame under the page for a fit and removes it otherwise.
    func updateFitFrame() {
        let current = subviews.first { $0 is BrowserFitFrameView }
        if tab?.deviceEmulation?.fit != nil, current == nil {
            addSubview(BrowserFitFrameView(), positioned: .below, relativeTo: subviews.first)
        } else if tab?.deviceEmulation?.fit == nil, let current {
            current.removeFromSuperview()
        }
        needsLayout = true
    }
}
