public import AppKit
public import CmuxNextWakeups
public import CmuxNextDesignTokens

/// Feeds one web view's page the wallpaper still its glass lenses (`window.cmuxTheme.backdrop`,
/// plans/cmux-next/glass-lens-DESIGN.md): the art of the backdrop behind the view, where it lies
/// in the page, its blur and the wash over it. A push carries only what changed since the last
/// one; the image (a JPEG data URL, ``GlassBackdropImages``) only when the art changed.
///
/// The owner calls ``refresh(newDocument:)`` after every theme push (with `newDocument` once a new
/// document loaded). A change of the art pushes again on the next display frame. A change of the
/// view's place in the window pushes when the place is final, never per frame of a motion:
/// at a render-server spring's start, whose frame is at rest
/// from then (``layoutWillRest()``), at a spring's landing (``landed()``), when a move of the pane
/// in the window ended (a strip or canvas camera, a pan, ``placementSettled()``), when the backdrop's
/// art takes a new size at rest or at a live window resize's end (``WindowMaterialView``), and for a
/// new size of the view at rest (``hostDidLayout()``). So a split, close or zoom spring evaluates at
/// most two scripts per page, and a window resize one.
///
/// This differs from Chromium on purpose. `RenderWidgetHostImpl::SynchronizeVisualProperties`
/// (`content/browser/renderer_host/render_widget_host_impl.cc`) sends every size or screen-rect
/// change, one message in flight until the renderer acks it, because the renderer must draw at its
/// new size. The lens rect is not a size the page draws at: it only aligns the refracted art, and
/// each push is a script that restyles every lens on the page's main thread. So during a motion the
/// lens keeps its last rect (off by the distance moved until the landing) and costs the page nothing.
/// Under `plain` glass, or with no still to lens, it does nothing.
///
/// While its page is hidden (``setPageShown(_:)``) the feed stops: it hears no backdrop, asks for no
/// frame and pushes nothing, so a hidden or frozen page gets no script from it. As Chrome's WebUI
/// handlers drop their observers in `OnJavascriptDisallowed` and send the current state in
/// `OnJavascriptAllowed` (content/public/browser/web_ui_message_handler.h), the show pushes what
/// changed meanwhile once, on its next frame.
///
/// ```swift
/// let feed = GlassBackdropFeed(host: pageView, zoom: { pageView.pageZoom }) { pageView.evaluate($0) }
/// feed.refresh(newDocument: true)
/// ```
@MainActor
public final class GlassBackdropFeed {
    private weak var host: NSView?
    private let zoom: @MainActor () -> Double
    private let evaluate: @MainActor (String) -> Void
    private let images: GlassBackdropImages
    private let mode: @MainActor () -> GlassLensMode
    private let scheduler: @MainActor (NSView) -> FrameScheduler
    private let liveResize: @MainActor (NSView) -> Bool
    /// What the page has; nil for a document that got nothing yet.
    private(set) var sent: GlassBackdropPayload?
    private weak var source: WindowMaterialView?
    /// The host's size at its last ``hostDidLayout()``.
    private var laidOutSize: CGSize?
    /// The one-shot frame that runs the next ``update()``; made on first use.
    private var nextFrame: FrameClient?
    /// False while the page is hidden (``setPageShown(_:)``).
    private(set) var pageShown = true
    /// Something asked for a push while the page was hidden: the show pushes.
    private var updateWhenShown = false
    /// The page holds the last push for later (``pushWasHeld()``): the next one carries every field, so it
    /// can take the held one's place.
    private var sendsWholeState = false

    /// - Parameters:
    ///   - host: The view the page's viewport fills.
    ///   - zoom: The page zoom (one CSS px is `zoom` points).
    ///   - images: Where stills are encoded and shared.
    ///   - mode: The glass mode pages draw now.
    ///   - scheduler: The frame scheduler of the host's window (``FrameScheduler/forView(_:)``; tests pass their own).
    ///   - liveResize: Whether a view is in a live window resize (`NSView.inLiveResize`; tests pass their own).
    ///   - evaluate: Runs a script in the page's main frame.
    public init(host: NSView, zoom: @escaping @MainActor () -> Double, images: GlassBackdropImages = .shared,
                mode: @escaping @MainActor () -> GlassLensMode = { .current },
                scheduler: @escaping @MainActor (NSView) -> FrameScheduler = { FrameScheduler.forView($0) },
                liveResize: @escaping @MainActor (NSView) -> Bool = { $0.inLiveResize },
                evaluate: @escaping @MainActor (String) -> Void) {
        self.host = host
        self.zoom = zoom
        self.images = images
        self.mode = mode
        self.scheduler = scheduler
        self.liveResize = liveResize
        self.evaluate = evaluate
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            nextFrame?.deactivate()
        }
    }

    /// Pushes what changed now, or when the page shows. `newDocument`: the page's document is new and has nothing yet.
    public func refresh(newDocument: Bool = false) {
        if newDocument { sent = nil }
        guard pageShown else {
            updateWhenShown = true
            return
        }
        update()
    }

    /// The page shows (true) or hides (false). Hidden, the feed stops hearing its backdrop and drops
    /// its pending frame. Shown again, it pushes on the next frame what changed while it was hidden (a
    /// push asked for meanwhile, or new art under a still the page lenses), and nothing when nothing did.
    public func setPageShown(_ shown: Bool) {
        guard shown != pageShown else { return }
        pageShown = shown
        guard shown else {
            nextFrame?.deactivate()
            follow(nil)
            return
        }
        guard updateWhenShown || lenses else { return }
        updateWhenShown = false
        setNeedsUpdate()
    }

    /// A layout spring starts or retargets (`PaneMotionTargeting`). On the render server the host's frame is
    /// set at rest in this turn (`PaneHostView.placeAtRest`), so the push on the next frame carries the rest
    /// place. A CPU spring's frame is still on its way: its landing pushes (``landed()``).
    public func layoutWillRest() {
        guard lenses, host?.enclosingFramePlacedAtRest == true else { return }
        setNeedsUpdate()
    }

    /// The layout spring, or the window's content-area motion, landed (`PaneMotionSettling`): the host is
    /// where it rests. The push on the next frame sends nothing when the page already has this place.
    public func landed() {
        guard lenses else { return }
        setNeedsUpdate()
    }

    /// The pane's place in the window changed and the layout's motion ended (`PanePlacementFollowing`): a
    /// strip or canvas camera landed, a pan ended, a close moved the pane with no animation. In a pane motion
    /// or a live window resize it waits for ``landed()`` or the resize's end.
    public func placementSettled() {
        guard lenses, let host, atRest(host) else { return }
        setNeedsUpdate()
    }

    /// The host laid out (its owner's `layout()`): a new size at rest (a divider released, a split with no
    /// animation) pushes on the next frame. In a pane motion or a live window resize it waits for
    /// ``landed()`` or the resize's end.
    public func hostDidLayout() {
        guard let host else { return }
        let size = host.bounds.size
        guard size != laidOutSize else { return }
        laidOutSize = size
        guard lenses, atRest(host) else { return }
        setNeedsUpdate()
    }

    /// The page did not run the push just sent: it holds the newest push for its thaw (a frozen page,
    /// MQ12), and a newer push takes the held one's place. Until a push runs, each one carries every
    /// field and the image, not only what changed since the held one.
    public func pushWasHeld() {
        sendsWholeState = true
    }

    /// Neither a live window resize nor a pane motion moves `host` now.
    private func atRest(_ host: NSView) -> Bool { !liveResize(host) && !host.isInPaneMotion }

    /// Whether the page has a still whose place a geometry change moves.
    private var lenses: Bool { sent?.key != nil }

    /// Pushes what changed on the next display frame its window is seen in: a hidden, minimized or
    /// covered window's page gets the push when it shows (or a capture vote holds its window).
    func setNeedsUpdate() {
        guard pageShown else {
            updateWhenShown = true
            return
        }
        let node = host?.window.map { WindowVisibilitySource.of($0).node }
        if let stale = nextFrame, stale.visibleOnly !== node {
            // The host moved to another window: the pending push follows that window's visibility.
            stale.deactivate()
            nextFrame = nil
        }
        // UI rate: the still does not follow the pointer.
        // frame-client: pushes the changed backdrop still at the next seen frame (one tick; view geometry, so on main)
        let client = nextFrame ?? FrameClient(owner: "glass.backdrop", isAnimation: false, rate: .ui, visibleOnly: node, scheduler: { [weak self] in
            guard let self, let host else { return .app }
            return scheduler(host)
        }) { [weak self] _ in
            self?.update()
            return false
        }
        nextFrame = client
        client.activate()
    }

    private func update() {
        guard let host, host.window != nil, mode().refracts else { return clear() }
        let backdrop = WindowMaterialView.glassBackdrop(behind: host)
        follow(backdrop)
        guard let backdrop, let image = backdrop.glassStill,
              let still = images.still(image, ready: { [weak self] in self?.setNeedsUpdate() }) else { return clear() }
        // Encoding: `ready` comes back; the page keeps what it has until then.
        guard let dataURL = still.dataURL else { return }
        guard !dataURL.isEmpty else { return clear() }
        let rect = GlassBackdropRect(imageSize: image.size, artFrame: backdrop.glassArtFrame,
                                     pageFrame: host.convert(host.bounds, to: nil), zoom: zoom())
        send(GlassBackdropPayload(key: still.key, rect: rect, blur: Double(backdrop.artBlurRadius) / zoom(),
                                  tint: GlassBackdropPayload.css(backdrop.tintColor)), image: dataURL)
    }

    /// Nothing to lens: the page drops its still once.
    private func clear() {
        follow(nil)
        guard let sent, sent.key != nil else { return }
        send(.none, image: nil)
    }

    private func send(_ payload: GlassBackdropPayload, image: String?) {
        guard let fields = payload.changes(since: sendsWholeState ? nil : sent, image: image),
              let script = GlassBackdropPayload.script(fields) else { return }
        sent = payload
        sendsWholeState = false
        evaluate(script) // a page that holds it calls pushWasHeld()
    }

    /// Hears art, blur and tint changes of `backdrop` (and of no other).
    private func follow(_ backdrop: WindowMaterialView?) {
        guard backdrop !== source else { return }
        source?.glassFeeds.remove(self)
        backdrop?.glassFeeds.add(self)
        source = backdrop
    }
}
