public import AppKit
public import CoreGraphics

/// A window's saved picture over its content while the live window is built under it (p08-startup-059, 060), and
/// what a click on it does (061). The picture is one layer (`contentsGravity` top-left), so drawing it costs no view
/// work. Regions (``WindowPictureMeta/Region``: the sidebar, each pane) turn live one by one; a click on a live
/// region goes through to the live view under the picture.
///
/// A click on a region that is not live yet is held, and its region's slice is raised to the next frame. When the
/// region goes live within ``holdLimit`` the click is sent again at the same window point (the mouse-down, then the
/// mouse-up when it came), so the live view gets it as if it had been there. It is dropped when the region's model
/// changed meanwhile (another tab selected: the point means something else now) or after the limit. A click outside
/// every region (the window's chrome) is sent again when the whole picture leaves.
///
/// A live resize, a size change (full screen, zoom) or a backing scale change removes the picture at once: its
/// pixels no longer match the window. The held clicks go with it, since their points no longer do either.
///
/// Chrome does the same with Android's startup paint preview: `PlayerCompositorDelegate` hands a tap on the preview
/// to the live tab only once it has painted, and a scroll or a resize removes the preview
/// (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/TabbedPaintPreview.java).
@MainActor
public final class LaunchPictureView: NSView {
    /// Why the picture left.
    public enum Leave: Sendable, Equatable {
        /// Every region is live, or the launch's bound passed (``finish()``).
        case finished
        /// The window's size or scale changed (a live resize, full screen, another display).
        case geometryChanged
    }

    /// What the picture asks of the live window.
    public struct Host {
        /// A token for what `region` shows in the model now (the pane's selected tab, the sidebar's rows); a held
        /// click whose region's token changed is dropped.
        public var modelStamp: @MainActor (_ region: WindowPictureMeta.Region) -> String?
        /// Builds `region`'s slice in the next frame (a click is waiting for it).
        public var raise: @MainActor (_ region: WindowPictureMeta.Region) -> Void
        /// Sends a held mouse event again through the app, behind the events already queued.
        public var resend: @MainActor (_ event: NSEvent) -> Void
        /// The picture left; the caller drops it.
        public var didLeave: @MainActor (_ reason: Leave) -> Void

        public init(modelStamp: @escaping @MainActor (_ region: WindowPictureMeta.Region) -> String?,
                    raise: @escaping @MainActor (_ region: WindowPictureMeta.Region) -> Void,
                    resend: @escaping @MainActor (_ event: NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) },
                    didLeave: @escaping @MainActor (_ reason: Leave) -> Void = { _ in }) {
            (self.modelStamp, self.raise, self.resend, self.didLeave) = (modelStamp, raise, resend, didLeave)
        }
    }

    /// How long a click waits for its region.
    public static let holdLimit: Duration = .seconds(2)

    public let meta: WindowPictureMeta
    /// The regions whose live view shows now (by ``WindowPictureMeta/Region/id``).
    public private(set) var liveRegions: Set<String> = []
    /// Whether the picture left (it shows nothing and takes no clicks).
    public private(set) var hasLeft = false
    private var clicks: LaunchPictureClicks
    private let host: Host
    private let pictureSize: CGSize
    private let now: @MainActor () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - picture: The decoded picture (``WindowPictureStore/FrontPicture/image``).
    ///   - scale: Its backing scale (``WindowPictureMeta/scale``): the layer shows it at its point size.
    ///   - now: The clock's reading (tests pass their own).
    public init(picture: CGImage, meta: WindowPictureMeta, scale: CGFloat, host: Host,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.meta = meta
        self.host = host
        self.now = now
        clicks = LaunchPictureClicks(limit: Self.holdLimit)
        pictureSize = CGSize(width: CGFloat(picture.width) / max(scale, 1), height: CGFloat(picture.height) / max(scale, 1))
        super.init(frame: CGRect(origin: .zero, size: pictureSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        if let layer {
            layer.contents = picture
            layer.contentsGravity = .topLeft
            layer.contentsScale = max(scale, 1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Regions

    /// The region under `point` (in this view's coordinates), the last listed winning.
    public func region(at point: CGPoint) -> WindowPictureMeta.Region? {
        let fromTop = CGPoint(x: point.x, y: bounds.height - point.y)
        return meta.regions.last { $0.frame.contains(fromTop) }
    }

    /// `id`'s live view shows now (its pixels left the picture): its clicks go through, and the ones held for it
    /// are sent again, unless its model changed or they waited too long.
    public func regionDidGoLive(_ id: String) {
        guard !hasLeft, liveRegions.insert(id).inserted else { return }
        var stamp: String?
        if let region = meta.regions.first(where: { $0.id == id }) { stamp = host.modelStamp(region) }
        for event in clicks.regionDidGoLive(id, stamp: stamp, at: now()) { host.resend(event) }
    }

    /// The picture leaves (every region is live, or the launch's bound passed): the clicks outside every region go
    /// to the live window; the ones still waiting for a region that is not live are dropped.
    public func finish() {
        guard !hasLeft else { return }
        let pending = clicks.finish(at: now())
        leave(.finished)
        for event in pending { host.resend(event) }
    }

    private func leave(_ reason: Leave) {
        hasLeft = true
        removeFromSuperview()
        host.didLeave(reason)
    }

    // MARK: Clicks

    public override func hitTest(_ point: CGPoint) -> NSView? {
        guard !hasLeft, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let region = region(at: local), liveRegions.contains(region.id) { return nil }
        return self
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) { press(event) }
    public override func rightMouseDown(with event: NSEvent) { press(event) }
    public override func otherMouseDown(with event: NSEvent) { press(event) }
    public override func mouseUp(with event: NSEvent) { release(event) }
    public override func rightMouseUp(with event: NSEvent) { release(event) }
    public override func otherMouseUp(with event: NSEvent) { release(event) }

    // A drag, a scroll or a hover on the picture means nothing: they are not passed on (no responder up the chain
    // acts on a window that is not built).
    public override func mouseDragged(with event: NSEvent) {}
    public override func rightMouseDragged(with event: NSEvent) {}
    public override func otherMouseDragged(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}

    private func press(_ event: NSEvent) {
        guard !hasLeft else { return }
        guard let region = region(at: convert(event.locationInWindow, from: nil)) else {
            clicks.press(event, region: nil, stamp: nil, at: now())
            return
        }
        clicks.press(event, region: region.id, stamp: host.modelStamp(region), at: now())
        host.raise(region)
    }

    private func release(_ event: NSEvent) {
        guard !hasLeft else { return }
        for sent in clicks.release(event) { host.resend(sent) }
    }

    // MARK: Geometry

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        leaveForGeometry()
    }

    public override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - pictureSize.width) >= 0.5 || abs(newSize.height - pictureSize.height) >= 0.5 { leaveForGeometry() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, abs(window.backingScaleFactor - CGFloat(meta.scale)) > 0.01 else { return }
        leaveForGeometry()
    }

    private func leaveForGeometry() {
        guard !hasLeft else { return }
        clicks.dropAll()
        leave(.geometryChanged)
    }
}

/// The clicks a ``LaunchPictureView`` holds, in the order pressed: which to send again when a region goes live or
/// the picture leaves, and which to drop.
@MainActor
public struct LaunchPictureClicks {
    struct Held {
        let down: NSEvent
        var up: NSEvent?
        /// The region pressed; nil outside every region.
        let region: String?
        let stamp: String?
        let at: ContinuousClock.Instant
        /// The mouse-down went out already: the mouse-up follows it at once.
        var sent = false
    }

    private var held: [Held] = []
    private let limit: Duration

    public init(limit: Duration) { self.limit = limit }

    /// Clicks still waiting.
    public var count: Int { held.count(where: { !$0.sent }) }

    /// A mouse-down on `region` (nil: outside every region) whose model reads `stamp` now.
    public mutating func press(_ down: NSEvent, region: String?, stamp: String?, at: ContinuousClock.Instant) {
        held.append(Held(down: down, region: region, stamp: stamp, at: at))
    }

    /// A mouse-up: it waits with its mouse-down, or goes now when that went already. Returns what to send now.
    public mutating func release(_ up: NSEvent) -> [NSEvent] {
        guard let index = held.lastIndex(where: { $0.up == nil && Self.pairs($0.down, up) }) else { return [] }
        if held[index].sent {
            held.remove(at: index)
            return [up]
        }
        held[index].up = up
        return []
    }

    /// `region` went live and its model reads `stamp`: its clicks within the limit whose stamp is the same, in
    /// order. Returns what to send now; the others of `region` are dropped.
    public mutating func regionDidGoLive(_ region: String, stamp: String?, at now: ContinuousClock.Instant) -> [NSEvent] {
        var send: [NSEvent] = []
        var kept: [Held] = []
        for var click in held {
            guard click.region == region, !click.sent else {
                kept.append(click)
                continue
            }
            guard click.stamp == stamp, click.at.duration(to: now) <= limit else { continue }
            send.append(click.down)
            if let up = click.up {
                send.append(up)
            } else {
                click.sent = true
                kept.append(click)
            }
        }
        held = kept
        return send
    }

    /// The picture leaves: the clicks outside every region within the limit, in order; every other is dropped.
    public mutating func finish(at now: ContinuousClock.Instant) -> [NSEvent] {
        var send: [NSEvent] = []
        for click in held where click.region == nil && !click.sent && click.at.duration(to: now) <= limit {
            send.append(click.down)
            if let up = click.up { send.append(up) }
        }
        held = []
        return send
    }

    public mutating func dropAll() { held = [] }

    /// Whether `up` ends the press `down` began (the same button).
    private static func pairs(_ down: NSEvent, _ up: NSEvent) -> Bool {
        switch (down.type, up.type) {
        case (.leftMouseDown, .leftMouseUp), (.rightMouseDown, .rightMouseUp): true
        case (.otherMouseDown, .otherMouseUp): down.buttonNumber == up.buttonNumber
        default: false
        }
    }
}
