public import AppKit
import CmuxNextWakeups

/// What decides whether a hover-revealed region shows its views.
public nonisolated struct HoverRevealState: Hashable, Sendable {
    /// False shows the views always (a setting such as
    /// `window.titlebarButtons` = always).
    public var isEnabled = true
    public var pointerInside = false
    /// Open holds: a drag, menu or popover that keeps the views shown.
    public var holds = 0
    /// One of the views (or a view inside one) has keyboard focus.
    public var focusInside = false

    public init() {}

    public var isRevealed: Bool { !isEnabled || pointerInside || holds > 0 || focusInside }
}

/// The one hover-reveal mechanism (R83 title bar buttons, R97 account icon,
/// R100 sidebar footer, R120 tab bar plus). Views added here fade in, in
/// place, while the pointer is over `region`, while a `Hold` is open, or
/// while one of them has keyboard focus; they fade out otherwise. Fading
/// changes only `alphaValue`: frames never move, the views stay in the
/// accessibility tree and keep taking clicks.
///
/// Invariant: the pointer inside the region always reveals before a click.
/// The tracking area reports entry and every move inside (so a layout change
/// under a still pointer is caught on the next move), and joining a window
/// reads the pointer's position once. There is no timer and no polling.
///
/// Timing is `MotionFade.hover` both ways (as every chrome hover):
/// `ui.animationSpeed` scales it, "off" is instant, and Reduce Motion keeps
/// it an opacity fade of at most 0.1 s. One instance per region and per
/// view: a second claim is refused (an assertion in debug builds).
@MainActor
public final class HoverReveal {
    /// A kept-open reveal. Release it (or drop it) to end the hold.
    @MainActor
    public final class Hold {
        private weak var owner: HoverReveal?
        private var isReleased = false
        private let generation: Int

        fileprivate init(owner: HoverReveal) {
            self.owner = owner
            generation = owner.generation
        }

        public func release() {
            guard !isReleased else { return }
            isReleased = true
            owner?.endHold(generation: generation)
        }

        isolated deinit { release() }
    }

    /// Debug builds assert when a view or region is claimed twice. Tests
    /// that check the refusal turn it off.
    public static var assertsOnConflict = true

    public private(set) var state = HoverRevealState()
    public var isRevealed: Bool { state.isRevealed }
    /// False shows the views always.
    public var isEnabled: Bool {
        get { state.isEnabled }
        set { update { $0.isEnabled = newValue } }
    }
    /// Called after the reveal changes (for work beyond the alpha fade).
    public var onChange: ((Bool) -> Void)?

    public private(set) weak var region: NSView?
    private var views: [ObjectIdentifier: Weak] = [:]
    /// Views whose keyboard focus reveals this region, without this reveal
    /// owning their alpha (`watchFocus(in:)`).
    private var focusViews: [ObjectIdentifier: Weak] = [:]
    private let probe: HoverRevealProbe
    /// Bumped when the window goes away, so older holds no longer count.
    fileprivate var generation = 0

    private static var viewOwners: [ObjectIdentifier: WeakReveal] = [:]
    private static var regionOwners: [ObjectIdentifier: WeakReveal] = [:]

    /// - Parameter tracking: `.activeAlways` for window chrome (hover shows
    ///   in a background window too), `.activeInKeyWindow` for sheets.
    /// - Parameter tracksPointer: False for a region that already tracks
    ///   the pointer itself (the tab strip) and reports it through
    ///   `setPointerInside`; focus and window tracking still apply.
    public init(region: NSView, tracking: NSTrackingArea.Options = .activeAlways, tracksPointer: Bool = true) {
        self.region = region
        probe = HoverRevealProbe(tracking: tracking, tracksPointer: tracksPointer)
        let key = ObjectIdentifier(region)
        if let other = Self.regionOwners[key]?.value, other !== self {
            Self.conflict("region already has a HoverReveal")
        } else {
            Self.regionOwners[key] = WeakReveal(self)
        }
        probe.owner = self
        probe.frame = region.bounds
        probe.autoresizingMask = [.width, .height]
        region.addSubview(probe, positioned: .below, relativeTo: nil)
    }

    isolated deinit {
        probe.removeFromSuperview()
        for key in views.keys where Self.viewOwners[key]?.value === self { Self.viewOwners[key] = nil }
        if let region, Self.regionOwners[ObjectIdentifier(region)]?.value === self {
            Self.regionOwners[ObjectIdentifier(region)] = nil
        }
    }

    /// The reveal that owns `view`, if any.
    public static func owner(of view: NSView) -> HoverReveal? { viewOwners[ObjectIdentifier(view)]?.value }
    /// The reveal installed on `region`, if any.
    public static func owner(ofRegion region: NSView) -> HoverReveal? { regionOwners[ObjectIdentifier(region)]?.value }

    /// Adds a view that fades with this region. Returns false (and adds
    /// nothing) when another HoverReveal already owns it.
    @discardableResult
    public func add(_ view: NSView) -> Bool {
        let key = ObjectIdentifier(view)
        if let other = Self.viewOwners[key]?.value, other !== self {
            Self.conflict("view already belongs to another HoverReveal")
            return false
        }
        Self.viewOwners[key] = WeakReveal(self)
        views[key] = Weak(view)
        view.alphaValue = isRevealed ? 1 : 0
        return true
    }

    /// Keyboard focus inside `view` reveals this region too, while another
    /// reveal (or nobody) owns `view`'s alpha: the top-left corner collapses
    /// the window controls and comes back for focus on any title bar button,
    /// while the title bar row's reveal fades those buttons.
    public func watchFocus(in view: NSView) {
        focusViews[ObjectIdentifier(view)] = Weak(view)
    }

    public func remove(_ view: NSView) {
        let key = ObjectIdentifier(view)
        guard views.removeValue(forKey: key) != nil else { return }
        if Self.viewOwners[key]?.value === self { Self.viewOwners[key] = nil }
        view.alphaValue = 1
    }

    /// For regions whose hover arrives another way (a click-catching panel
    /// over a Chromium page, a drag session).
    public func setPointerInside(_ inside: Bool) {
        update { $0.pointerInside = inside }
    }

    /// Keeps the views shown until the hold is released.
    public func hold() -> Hold {
        update { $0.holds += 1 }
        return Hold(owner: self)
    }

    fileprivate func endHold(generation: Int) {
        guard generation == self.generation else { return }
        update { $0.holds = max(0, $0.holds - 1) }
    }

    /// The region left its window (it closed or the view moved): nothing
    /// is hovered, held or focused any more.
    fileprivate func windowWillChange() {
        generation += 1
        update {
            $0.pointerInside = false
            $0.holds = 0
            $0.focusInside = false
        }
    }

    /// Re-reads keyboard focus: a first responder inside an added view.
    fileprivate func focusDidChange(_ responder: NSResponder?) {
        let view = responder as? NSView
        let inside = view.map { focused in
            views.values.contains { $0.value.map { focused.isDescendant(of: $0) } ?? false }
                || focusViews.values.contains { $0.value.map { focused.isDescendant(of: $0) } ?? false }
        } ?? false
        update { $0.focusInside = inside }
    }

    private func update(_ change: (inout HoverRevealState) -> Void) {
        let wasRevealed = state.isRevealed
        change(&state)
        guard state.isRevealed != wasRevealed else { return }
        let alpha: CGFloat = state.isRevealed ? 1 : 0
        let targets = views.values.compactMap(\.value)
        Motion.animate(.hover, in: region) {
            for view in targets { view.animator().alphaValue = alpha }
        }
        onChange?(state.isRevealed)
    }

    private static func conflict(_ message: String) {
        if assertsOnConflict { assertionFailure("HoverReveal: \(message)") }
    }

    private struct Weak {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    private struct WeakReveal {
        weak var value: HoverReveal?
        init(_ value: HoverReveal) { self.value = value }
    }
}

/// An invisible full-size subview of the region: it owns the tracking area
/// and follows the region's window (focus changes, close). It takes no
/// clicks and draws nothing.
private final class HoverRevealProbe: NSView {
    weak var owner: HoverReveal?
    private let trackingOptions: NSTrackingArea.Options
    private let tracksPointer: Bool
    private var focusObservation: NSKeyValueObservation?
    private var closeObserver: Task<Void, Never>?

    init(tracking: NSTrackingArea.Options, tracksPointer: Bool) {
        trackingOptions = tracking
        self.tracksPointer = tracksPointer
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        closeObserver?.cancel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let own = trackingAreas.filter { $0.owner === self }
        // An unchanged rect keeps its area. Replacing it on every call (each layout pass of the
        // sidebar slide) dropped an exit that arrived between the removal and the new area, and the
        // new area, added with the pointer already outside, never reported it, so the reveal stayed
        // on (Lawrence 2026-10-05, nxdog55: the window controls with the sidebar closed).
        if tracksPointer, own.count == 1, own[0].rect == bounds { return }
        for area in own { removeTrackingArea(area) }
        guard tracksPointer else { return }
        // Exactly the bounds, not `.inVisibleRect`: the visible rect of a view that does not clip
        // reaches past its bounds (nxdog43: the whole window), so the pointer never "left" until it
        // left the window. AppKit calls this again whenever the bounds change.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, trackingOptions], owner: self))
        // A new area cannot know an exit the old one missed: read where the pointer is now.
        readPointer()
    }

    /// Sets "inside" from the pointer's position now. A window that is not
    /// shown cannot be under the pointer.
    private func readPointer() {
        guard tracksPointer, let window, let owner else { return }
        let inside = window.isVisible && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside != owner.state.pointerInside { owner.setPointerInside(inside) }
    }

    /// The tracked rect follows the bounds even when the visible rect does not change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { owner?.setPointerInside(true) }
    override func mouseMoved(with event: NSEvent) {
        if owner?.state.pointerInside == false { owner?.setPointerInside(true) }
    }
    override func mouseExited(with event: NSEvent) { owner?.setPointerInside(false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        focusObservation = nil
        closeObserver?.cancel()
        closeObserver = nil
        owner?.windowWillChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        focusObservation = window.observe(\.firstResponder, options: [.initial, .new]) { @Sendable [weak self] window, _ in
            // KVO calls back synchronously on the changing thread: inline on main (a hop would reveal a focused button a turn late), a hop from anywhere else.
            MainDelivery().run { self?.owner?.focusDidChange(window.firstResponder) }
        }
        // task-owner: the probe (cancelled when it leaves the window or deinits); event-driven.
        closeObserver = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window) {
                self?.owner?.windowWillChange()
            }
        }
        // A pointer already over the region when it joins a shown window
        // reveals at once, before any click (no mouseEntered arrives for
        // it). A window that is not on screen cannot be under the pointer.
        readPointer()
    }
}
