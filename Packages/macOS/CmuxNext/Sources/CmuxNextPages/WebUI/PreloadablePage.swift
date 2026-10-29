public import AppKit
public import CoreGraphics

/// A page the preload slot (``PagePreloadSlot``) can load ahead out of sight, park and hand to a tab:
/// a cmux page (``PageWebView``) or the New Tab agent pane, on either
/// engine.
///
/// The slot drives the page in Chrome's order (webui_contents_preload_manager.cc): it loads visible,
/// so its resources and first paint run at once, then hides; a freeze comes only after the hide, and
/// a thaw comes before the page is shown again. Every call is O(1) on the main actor
/// and none waits: the two callbacks run in a later turn.
@MainActor
public protocol PreloadablePage: AnyObject {
    /// The view the slot holds in its parking and reparents into the claiming tab.
    var preloadView: NSView { get }
    /// The page's id on the `webui.preload` trace track (``PageWebView/traceID`` for a page).
    var preloadTraceID: UInt64 { get }
    /// Calls `body` once, on the main actor, when the page next presents a frame after this call,
    /// once its document has loaded (a load event and its first non-empty paint for a new page).
    /// A resize or a show presents a frame on both engines, so a refit and a claim always get one.
    func preloadWhenPainted(_ body: @escaping @MainActor () -> Void)
    /// Takes the frame the page shows now as its cover and calls `body` once with it, on the main
    /// actor (nil when the engine gives no picture). The slot asks only while the page is visible.
    func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void)
    /// Tells the engine that the page is visible or hidden (`document.visibilityState`); the view
    /// stays where it is.
    func preloadSetVisible(_ visible: Bool)
    /// Hidden to frozen: no task, timer or frame runs; the page keeps its memory. Called only after
    /// `preloadSetVisible(false)`.
    ///
    /// - Returns: Whether the engine froze it, as p13-webui-028's `setFrozen(_:)`: false when it
    ///   refuses (a shown page, a Chromium fork before `SetPageFrozen`); the page then waits hidden
    ///   and running, and gets no thaw.
    func preloadFreeze() -> Bool
    /// Frozen to running. Called before `preloadSetVisible(true)`, and only on a frozen page.
    func preloadThaw()
    /// Ends the page: the slot dropped it unclaimed (pressure, another preload).
    func close()
}

/// Where a preloaded page waits: in a window, so the engine renders it, out of the person's sight
/// and input, at the size the slot gives.
@MainActor
public protocol PreloadParking: AnyObject {
    /// Holds `view` (adding it when it is not in the parking yet) at `size`, laid out now, so the
    /// page commits at the size it will show at.
    func hold(_ view: NSView, at size: NSSize)
}

/// The parking for a window: transparent, far outside the window's content (a web view's tracking
/// areas ignore alpha and hit testing), never hit by the mouse, and out of the accessibility tree.
/// Add it to the window's content view; a claim reparents its page out of it.
///
/// The one parking of the program: the Settings, History and Cloud preload waits here (045 deleted
/// PageHostPool and its parking), and p13-webui-044 moves the New Tab spare here from `NewTabSpareParking`.
public final class PagePreloadParkingView: NSView, PreloadParking {
    /// The parking's frame in its superview's `bounds`: `size`, far outside the content.
    public static func frame(in bounds: NSRect, size: NSSize) -> NSRect {
        NSRect(origin: NSPoint(x: bounds.minX - 100_000, y: bounds.minY - 100_000), size: size)
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        autoresizingMask = []
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func hold(_ view: NSView, at size: NSSize) {
        if let superview { frame = Self.frame(in: superview.bounds, size: size) } else { setFrameSize(size) }
        if view.superview !== self { addSubview(view) }
        view.frame = bounds
        // sync-layout: the held page lays out at its size in the slot's no-actions transaction, before the slot waits for its paint there.
        layoutSubtreeIfNeeded()
    }

    /// Added after a hold: it goes far outside its new superview's content at the size it holds.
    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview { frame = Self.frame(in: superview.bounds, size: frame.size) }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public var acceptsFirstResponder: Bool { false }
    override public func accessibilityChildren() -> [Any]? { [] }

    #if DEBUG || CMUX_BENCH_HOOKS
    // `debug.webui`: a parked page is hidden to the person.
    override public func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        PageWebView.noteCensusParked(true, in: subview)
    }

    override public func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        PageWebView.noteCensusParked(false, in: subview)
    }
    #endif
}
