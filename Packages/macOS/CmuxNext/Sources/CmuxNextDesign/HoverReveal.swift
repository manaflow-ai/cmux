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
/// while one of them has keyboard focus; they fade out (to `restAlpha`) otherwise. Fading
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

        // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
        // Reads Sendable state only; the reveal's change runs on the main thread, inline when the hold is
        // dropped there (as before), a hop from any other thread (that release was skipped before, and
        // the views stayed shown).
        nonisolated deinit {
            guard !isReleased, let owner else { return }
            let generation = generation
            MainDelivery().run { owner.endHold(generation: generation) }
        }
    }

    /// Debug builds assert when a view or region is claimed twice. Tests
    /// that check the refusal turn it off.
    public static var assertsOnConflict = true

    public private(set) var state = HoverRevealState()
    public var isRevealed: Bool { state.isRevealed }
    /// The views' alpha at rest: 0 hides them (the default); more shows them muted, as the tab bar's
    /// plus and "…" do (Leo 2026-10-19: a hidden control's kept room read as an empty gap).
    public var restAlpha: CGFloat = 0 {
        didSet {
            guard restAlpha != oldValue, !isRevealed else { return }
            for view in views.values.compactMap(\.value) { view.alphaValue = restAlpha }
        }
    }
    /// False shows the views always.
    public var isEnabled: Bool {
        get { state.isEnabled }
        set { update { $0.isEnabled = newValue } }
    }
    /// Called after the reveal changes (for work beyond the alpha fade).
    public var onChange: ((Bool) -> Void)?
    /// Called after any input changes (pointer, focus, holds, enabled),
    /// also when the reveal itself does not: a consumer that needs the
    /// inputs rather than the result (the collapsed toolbar band opens on
    /// the pointer even while `window.titlebarButtons` = always).
    public var onStateChange: ((HoverRevealState) -> Void)?

    public private(set) weak var region: NSView?
    /// The region's identity, kept for the deinit (the weak `region` may read nil by then).
    private let regionKey: ObjectIdentifier
    private var views: [ObjectIdentifier: Weak] = [:]
    /// Views whose keyboard focus reveals this region, without this reveal
    /// owning their alpha (`watchFocus(in:)`).
    private var focusViews: [ObjectIdentifier: Weak] = [:]
    private let probe: HoverRevealProbe
    /// Bumped when the window goes away, so older holds no longer count.
    fileprivate var generation = 0

    private static var viewOwners: [ObjectIdentifier: WeakReveal] = [:]
    private static var regionOwners: [ObjectIdentifier: WeakReveal] = [:]
    /// The reveals that watch focus in a view (`watchFocus(in:)`), by view.
    private static var focusWatchers: [ObjectIdentifier: [WeakReveal]] = [:]

    /// - Parameter tracking: `.activeAlways` for window chrome (hover shows
    ///   in a background window too), `.activeInKeyWindow` for sheets.
    /// - Parameter tracksPointer: False for a region that already tracks
    ///   the pointer itself (the tab strip) and reports it through
    ///   `setPointerInside`; focus and window tracking still apply.
    public init(region: NSView, tracking: NSTrackingArea.Options = .activeAlways, tracksPointer: Bool = true) {
        self.region = region
        let key = ObjectIdentifier(region)
        regionKey = key
        probe = HoverRevealProbe(tracking: tracking, tracksPointer: tracksPointer)
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

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Reads Sendable state only (the probe and the registry keys); the view and registry work runs on the
    // main thread, inline when the reveal is released there (as before), a hop from any other thread
    // (skipped before: the probe stayed in the region). By now every weak reference to this reveal reads
    // nil, so under its keys the released entries are the ones whose reveal reads nil (an entry another
    // reveal claimed since then stays).
    nonisolated deinit {
        let probe = probe
        let keys = RegistryKeys(views: Array(views.keys), focusViews: Array(focusViews.keys), region: regionKey)
        MainDelivery().run {
            probe.removeFromSuperview()
            HoverReveal.dropReleasedEntries(under: keys)
        }
    }

    /// The registry keys a reveal claimed, read in its deinit.
    private struct RegistryKeys: Sendable {
        let views: [ObjectIdentifier]
        let focusViews: [ObjectIdentifier]
        let region: ObjectIdentifier
    }

    /// Drops the view, region and focus-watcher entries under `keys` whose reveal is gone (a reveal's
    /// deinit). The view and region registries had no other removal for a released reveal, so they grew
    /// with every pane and tab strip that closed.
    private static func dropReleasedEntries(under keys: RegistryKeys) {
        for key in keys.views where viewOwners[key].map({ $0.value == nil }) == true { viewOwners[key] = nil }
        if regionOwners[keys.region].map({ $0.value == nil }) == true { regionOwners[keys.region] = nil }
        for key in keys.focusViews {
            guard let watchers = focusWatchers[key] else { continue }
            let live = watchers.filter { $0.value != nil }
            guard live.count != watchers.count else { continue }
            focusWatchers[key] = live.isEmpty ? nil : live
        }
    }

    /// The reveal that owns `view`, if any.
    public static func owner(of view: NSView) -> HoverReveal? { viewOwners[ObjectIdentifier(view)]?.value }
    /// The reveal installed on `region`, if any.
    public static func owner(ofRegion region: NSView) -> HoverReveal? { regionOwners[ObjectIdentifier(region)]?.value }
    /// Whether any registry still has an entry (live or released) under `view` or `region`: a view or
    /// region claim, or a focus watch on `view`. Tests read it to prove a released reveal leaves none behind.
    static func hasRegistryEntries(view: NSView, region: NSView) -> Bool {
        viewOwners[ObjectIdentifier(view)] != nil || regionOwners[ObjectIdentifier(region)] != nil
            || focusWatchers[ObjectIdentifier(view)] != nil
    }

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
        view.alphaValue = isRevealed ? 1 : restAlpha
        return true
    }

    /// Keyboard focus inside `view` reveals this region too, while another
    /// reveal (or nobody) owns `view`'s alpha: the top-left corner collapses
    /// the window controls and comes back for focus on any title bar button,
    /// while the title bar row's reveal fades those buttons.
    public func watchFocus(in view: NSView) {
        let key = ObjectIdentifier(view)
        focusViews[key] = Weak(view)
        Self.focusWatchers[key, default: []].removeAll { $0.value == nil || $0.value === self }
        Self.focusWatchers[key, default: []].append(WeakReveal(self))
    }

    /// The reveals whose keyboard focus covers `view` itself (it is an added or watched view):
    /// a focus change walks the responder's superviews through this (`HoverRevealFocusRouter`).
    fileprivate static func reveals(focusingOn view: NSView) -> [HoverReveal] {
        let key = ObjectIdentifier(view)
        var found: [HoverReveal] = []
        if let owner = viewOwners[key]?.value, owner.views[key]?.value === view { found.append(owner) }
        for watcher in focusWatchers[key] ?? [] {
            if let reveal = watcher.value, reveal.focusViews[key]?.value === view { found.append(reveal) }
        }
        return found
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

    /// Whether `responder` is inside an added or watched view (read once when the region joins a window).
    fileprivate func containsFocus(_ responder: NSResponder?) -> Bool {
        guard let focused = responder as? NSView else { return false }
        return views.values.contains { $0.value.map { focused.isDescendant(of: $0) } ?? false }
            || focusViews.values.contains { $0.value.map { focused.isDescendant(of: $0) } ?? false }
    }

    fileprivate func setFocusInside(_ inside: Bool) {
        update { $0.focusInside = inside }
    }

    private func update(_ change: (inout HoverRevealState) -> Void) {
        let old = state
        change(&state)
        if state != old { onStateChange?(state) }
        guard state.isRevealed != old.isRevealed else { return }
        let alpha: CGFloat = state.isRevealed ? 1 : restAlpha
        let targets = views.values.compactMap(\.value)
        Motion.feedback.animate(.hover, in: region) {
            for view in targets { view.animator().alphaValue = alpha }
        }
        onChange?(state.isRevealed)
    }

    private static func conflict(_ message: String) {
        if assertsOnConflict { assertionFailure("HoverReveal: \(message)") }
    }

    private struct Weak: Sendable {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    fileprivate struct WeakReveal {
        weak var value: HoverReveal?
        init(_ value: HoverReveal) { self.value = value }
    }
}

/// One first-responder observation per window for every reveal in it (cx-8w027.25). A change
/// walks the new responder's superviews once and tells only the reveals it enters or leaves:
/// O(view depth) per focus change, where one observation per reveal re-read every reveal of the
/// window (two per pane, ~5 ms per tab switch at 16 panes).
@MainActor
private final class HoverRevealFocusRouter {
    private static var routers: [ObjectIdentifier: HoverRevealFocusRouter] = [:]

    private weak var window: NSWindow?
    private var observation: NSKeyValueObservation?
    /// Reveals whose region is in the window, by reveal.
    private var members: [ObjectIdentifier: HoverReveal.WeakReveal] = [:]
    /// Members that have the focus now.
    private var focused: [ObjectIdentifier: HoverReveal.WeakReveal] = [:]

    /// `reveal`'s region joined `window`: it reads the focus now and follows every change.
    static func join(_ reveal: HoverReveal, window: NSWindow) {
        // A window that went away without its reveals leaving drops its router (its address may be reused).
        routers = routers.filter { $0.value.window != nil }
        let router = routers[ObjectIdentifier(window)].flatMap { $0.window === window ? $0 : nil } ?? {
            let router = HoverRevealFocusRouter()
            router.window = window
            routers[ObjectIdentifier(window)] = router
            router.observation = window.observe(\.firstResponder, options: [.new]) { @Sendable [weak router] window, _ in
                // KVO calls back synchronously on the changing thread: inline on main (a hop would reveal a focused button a turn late), a hop from anywhere else.
                MainDelivery().run { router?.responderDidChange(window.firstResponder) }
            }
            return router
        }()
        let key = ObjectIdentifier(reveal)
        router.members[key] = HoverReveal.WeakReveal(reveal)
        let inside = reveal.containsFocus(window.firstResponder)
        router.focused[key] = inside ? HoverReveal.WeakReveal(reveal) : nil
        reveal.setFocusInside(inside)
    }

    /// The reveal `key` left `window` (or went away); the window's observation ends with its last reveal.
    static func leave(_ key: ObjectIdentifier, window: NSWindow) {
        let windowKey = ObjectIdentifier(window)
        guard let router = routers[windowKey], router.window === window else { return }
        router.members[key] = nil
        router.focused[key] = nil
        router.members = router.members.filter { $0.value.value != nil }
        if router.members.isEmpty {
            router.observation = nil
            routers[windowKey] = nil
        }
    }

    /// The reveal `key`'s window closed (its focus ends; it stays a member for a window shown again).
    static func forgetFocus(_ key: ObjectIdentifier, window: NSWindow) {
        guard let router = routers[ObjectIdentifier(window)], router.window === window else { return }
        router.focused[key] = nil
    }

    private func responderDidChange(_ responder: NSResponder?) {
        var now: [ObjectIdentifier: HoverReveal] = [:]
        var view = responder as? NSView
        while let current = view {
            for reveal in HoverReveal.reveals(focusingOn: current) where members[ObjectIdentifier(reveal)]?.value === reveal {
                now[ObjectIdentifier(reveal)] = reveal
            }
            view = current.superview
        }
        let left = focused.filter { now[$0.key] == nil }.compactMap(\.value.value)
        let entered = now.filter { focused[$0.key] == nil }.map(\.value)
        focused = now.mapValues { HoverReveal.WeakReveal($0) }
        for reveal in left { reveal.setFocusInside(false) }
        for reveal in entered { reveal.setFocusInside(true) }
    }
}

/// An invisible full-size subview of the region: it owns the tracking area
/// and follows the region's window (focus changes, close). It takes no
/// clicks and draws nothing.
private final class HoverRevealProbe: NSView {
    weak var owner: HoverReveal? {
        didSet { ownerKey = owner.map { ObjectIdentifier($0) } }
    }
    /// The owner's identity, for leaving the focus router after the owner went away.
    private var ownerKey: ObjectIdentifier?
    /// The window whose focus router this probe's owner joined.
    private weak var routedWindow: NSWindow?
    private let trackingOptions: NSTrackingArea.Options
    private let tracksPointer: Bool
    private var closeObserver: Task<Void, Never>?

    init(tracking: NSTrackingArea.Options, tracksPointer: Bool) {
        trackingOptions = tracking
        self.tracksPointer = tracksPointer
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Sendable cleanup only (`Task.cancel()`), so it runs on whatever thread releases the probe.
    nonisolated deinit {
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
        if let routedWindow, let ownerKey { HoverRevealFocusRouter.leave(ownerKey, window: routedWindow) }
        routedWindow = nil
        closeObserver?.cancel()
        closeObserver = nil
        owner?.windowWillChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if let owner {
            HoverRevealFocusRouter.join(owner, window: window)
            routedWindow = window
        }
        // task-owner: the probe (cancelled when it leaves the window or deinits); event-driven.
        closeObserver = Task { @MainActor [weak self, weak window] in
            guard let window else { return }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification, object: window) {
                if let key = self?.ownerKey { HoverRevealFocusRouter.forgetFocus(key, window: window) }
                self?.owner?.windowWillChange()
            }
        }
        // A pointer already over the region when it joins a shown window
        // reveals at once, before any click (no mouseEntered arrives for
        // it). A window that is not on screen cannot be under the pointer.
        readPointer()
    }
}
