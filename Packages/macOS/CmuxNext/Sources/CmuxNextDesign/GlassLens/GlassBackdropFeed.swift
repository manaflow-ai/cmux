public import AppKit
import CmuxNextWakeups
import CmuxNextCompat
public import CmuxNextDesignTokens

/// Feeds one web view's page the wallpaper still its glass lenses (`window.cmuxTheme.backdrop`,
/// plans/cmux-next/glass-lens-DESIGN.md): the art of the backdrop behind the view, where it lies
/// in the page, its blur and the wash over it. A push carries only what changed since the last
/// one; the image (a JPEG data URL, ``GlassBackdropImages``) only when the art changed.
///
/// The owner calls ``refresh(newDocument:)`` after every theme push (with `newDocument` once a new
/// document loaded). Changes of the art and of the view's place in the window (window resize,
/// split resize, sidebar toggle, a strip scroll) push again on the next display frame, at most
/// once per frame. Under `plain` glass, or with no still to lens, it does nothing and watches
/// nothing.
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
    /// What the page has; nil for a document that got nothing yet.
    private(set) var sent: GlassBackdropPayload?
    private weak var source: WindowMaterialView?
    /// The views whose frame or bounds move the page in the window, and their observers.
    private var watched: [ObjectIdentifier] = []
    private var observers: [MainActorObservation] = []
    /// The one-shot frame that runs the next ``update()``; made on first use.
    private var nextFrame: FrameClient?

    /// - Parameters:
    ///   - host: The view the page's viewport fills.
    ///   - zoom: The page zoom (one CSS px is `zoom` points).
    ///   - images: Where stills are encoded and shared.
    ///   - mode: The glass mode pages draw now.
    ///   - evaluate: Runs a script in the page's main frame.
    public init(host: NSView, zoom: @escaping @MainActor () -> Double, images: GlassBackdropImages = .shared,
                mode: @escaping @MainActor () -> GlassLensMode = { .current }, evaluate: @escaping @MainActor (String) -> Void) {
        self.host = host
        self.zoom = zoom
        self.images = images
        self.mode = mode
        self.evaluate = evaluate
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            nextFrame?.deactivate()
        }
    }

    /// Pushes what changed now. `newDocument`: the page's document is new and has nothing yet.
    public func refresh(newDocument: Bool = false) {
        if newDocument { sent = nil }
        update()
    }

    /// Pushes what changed on the next display frame.
    func setNeedsUpdate() {
        let client = nextFrame ?? FrameClient(owner: "glass.backdrop", isAnimation: false,
                                              scheduler: { [weak self] in self?.host.map(FrameScheduler.forView) ?? .app }) { [weak self] _ in
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
        guard let dataURL = still.dataURL else { return watch(host, backdrop) }
        guard !dataURL.isEmpty else { return clear() }
        watch(host, backdrop)
        let rect = GlassBackdropRect(imageSize: image.size, artFrame: backdrop.glassArtFrame,
                                     pageFrame: host.convert(host.bounds, to: nil), zoom: zoom())
        send(GlassBackdropPayload(key: still.key, rect: rect, blur: Double(backdrop.artBlurRadius) / zoom(),
                                  tint: GlassBackdropPayload.css(backdrop.tintColor)), image: dataURL)
    }

    /// Nothing to lens: the page drops its still once, and nothing is watched.
    private func clear() {
        follow(nil)
        unwatch()
        guard let sent, sent.key != nil else { return }
        send(.none, image: nil)
    }

    private func send(_ payload: GlassBackdropPayload, image: String?) {
        guard let fields = payload.changes(since: sent, image: image), let script = GlassBackdropPayload.script(fields) else { return }
        sent = payload
        evaluate(script)
    }

    /// Hears art, blur and tint changes of `backdrop` (and of no other).
    private func follow(_ backdrop: WindowMaterialView?) {
        guard backdrop !== source else { return }
        source?.glassFeeds.remove(self)
        backdrop?.glassFeeds.add(self)
        source = backdrop
    }

    /// Hears frame and bounds changes of `host`, its ancestors and `backdrop`: any of them moves
    /// the page or the art in the window.
    private func watch(_ host: NSView, _ backdrop: WindowMaterialView) {
        var views: [NSView] = [backdrop]
        var view: NSView? = host
        while let current = view {
            views.append(current)
            view = current.superview
        }
        let ids = views.map(ObjectIdentifier.init)
        guard ids != watched else { return }
        unwatch()
        watched = ids
        let center = NotificationCenter.default
        for watchedView in views {
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                observers.append(MainActorObservation(name, object: watchedView, center: center) { [weak self] in
                    self?.setNeedsUpdate()
                })
            }
        }
    }

    private func unwatch() {
        observers = []
        watched = []
    }
}
