public import AppKit
public import CmuxNextDesignTokens

/// The one thin scroller of cmux NEXT's native scroll views: the sidebar's list and pinned bands,
/// the Priority view, every scrollable card (hover cards, the update card's popover) and the
/// terminal. Its web twin is the shared page scroller (webviews/src/scrollers.ts).
///
/// A rounded knob at the trailing edge (a sideways scroller's: the bottom edge), on no track, in the
/// label color at low contrast. It behaves
/// as a macOS overlay scroller (Lawrence 2026-10-23, msg 11494: "auto-fades away, and grows bigger
/// on near-hover so it's easier to grab"):
///
/// - It shows while the user scrolls the view and fades out ``restDelay`` after the last step.
/// - Its grab zone (``grabZone``: the scroller's own strip, ``width`` wide at the trailing edge, a
///   sideways scroller's at the bottom edge) is one rect for the pointer and for a press: the
///   pointer over it shows the knob and widens it from ``knobThickness`` to
///   ``expandedKnobThickness``, and a press there grabs the knob or pages the track, pixel for
///   pixel the same columns (Lawrence 2026-11-20, msg 42498: "it is possible for me to hover close,
///   and for the width to change, but after i mousedown and drag, it fails to scroll"). Anywhere
///   else, and while the knob would not widen, a press is the content's.
/// - A grabbed knob follows the pointer 1:1 until the release, also once the pointer leaves the
///   bar; it stays wide while it is dragged.
/// - Fades and the grow go through the ``MotionCategory/feedback`` gate: Reduce Motion, calm mode
///   and the animation switches apply (the grow snaps when movement does not animate).
///
/// With ``autoHides`` false (``SystemScrollers/thinScrollersAutoHide``) the knob stays shown for as
/// long as the content overflows, the look before Oct 23. It is always an overlay scroller, so it
/// never takes width from the content. Give a scroll view this scroller with
/// ``SystemScrollers/followThin(_:)``; never style a scroller by hand.
///
/// ```swift
/// scrollView.hasVerticalScroller = true
/// SystemScrollers.followThin(scrollView)
/// ```
public final class ThinScroller: NSScroller {
    /// The drawn knob's width at rest, in points.
    public static let knobThickness: CGFloat = 3
    /// The drawn knob's width while the pointer is near or the knob is dragged, in points.
    public static let expandedKnobThickness: CGFloat = 7
    /// The scroller's width, which is its grab zone's (``grabZone``): the wide knob, 2 pt to the
    /// edge and 5 pt of reach inward, about a macOS overlay scroller's. The web twin's lane is the
    /// scrollbar WebKit draws (webviews/src/scrollers.ts `scrollbarLane`).
    public static let width: CGFloat = 14
    /// How long the knob stays after the last scroll step (the web twin's `SCROLLING_HIDE_MS`).
    public static let restDelay: Duration = .milliseconds(800)
    /// The knob's opacity over the label color, at rest and wide.
    static let knobAlpha: CGFloat = 0.32
    static let expandedKnobAlpha: CGFloat = 0.5

    /// True fades the knob out at rest; false keeps it shown while the content overflows.
    public var autoHides: Bool {
        get { presence.autoHides }
        set { update { $0.autoHides = newValue } }
    }

    /// True (the default, the terminal's too): the pointer near the edge reveals a hidden knob.
    /// False: the pointer only holds and widens a knob already shown.
    public var revealsNearPointerAtRest: Bool {
        get { presence.revealsNearPointerAtRest }
        set { update { $0.revealsNearPointerAtRest = newValue } }
    }

    /// True shows the knob while the user scrolls the scroll view (AppKit's live scroll: wheel,
    /// trackpad, a knob drag), never for a scroll the app makes or a layout. The terminal turns it
    /// off and calls ``flash()`` itself: output that only follows the bottom is not a scroll.
    public var showsOnScroll = true

    /// The knob that is drawn. AppKit draws an overlay scroller's own knob into a layer it fades on
    /// its own schedule, so the knob is a view of its own whose fade and width this scroller owns.
    let restingKnob = ThinScrollerKnobView()
    private(set) var presence = ThinScrollerPresence()
    private let clock: any Clock<Duration>
    // The app uses the default center; tests inject an isolated center so a
    // synthetic scroll cannot notify unrelated process-global observers.
    let notificationCenter: NotificationCenter
    /// The pending fade-out after the last scroll; the next scroll cancels it.
    private(set) var restTask: Task<Void, Never>?
    private var proximity: ThinScrollerProximity?
    private var drawnExpanded = false
    /// True: a press on the track jumps the knob to the pressed spot; false pages toward it. The
    /// macOS setting "Click in the scroll bar to" (Option inverts it for one press, as AppKit's).
    var jumpsToClickedSpot: () -> Bool = { UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior") }

    override public convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, clock: ContinuousClock())
    }

    /// A scroller whose rest delay runs on `clock`.
    ///
    /// - Parameters:
    ///   - frameRect: The scroller's frame.
    ///   - clock: The clock of ``restDelay``; tests pass a manual clock.
    public init(frame frameRect: NSRect, clock: any Clock<Duration>, notificationCenter: NotificationCenter = .default) {
        self.clock = clock
        self.notificationCenter = notificationCenter
        super.init(frame: frameRect)
        restingKnob.wantsLayer = true
        addSubview(restingKnob)
        presence.autoHides = SystemScrollers.thinScrollersAutoHide
        placeKnob(animated: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public class var isCompatibleWithOverlayScrollers: Bool { true }

    /// AppKit's arrow and page parts, named (``ScrollerPartNames``).
    /// True while the parts are being named: a part answers its attributes through this scroller's
    /// children, so a read while naming returns them unnamed instead of naming again (which recursed).
    private var namingParts = false

    override public func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        guard !namingParts else { return children }
        namingParts = true
        defer { namingParts = false }
        ScrollerPartNames.name(children, vertical: bounds.height >= bounds.width)
        return children
    }

    override public class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        width
    }

    /// A sideways scroller (a scroll view's horizontal bar): wider than tall, as AppKit tells them apart.
    public var isHorizontal: Bool { bounds.width > bounds.height }

    /// The knob drawn for AppKit's knob slot `rect`: its length, ``knobThickness`` wide (or
    /// ``expandedKnobThickness`` when `expanded`), 2 pt in from the scroller's trailing edge (a
    /// sideways scroller's bottom edge).
    public func knobRect(for rect: CGRect, expanded: Bool = false) -> CGRect {
        let thickness = expanded ? Self.expandedKnobThickness : Self.knobThickness
        guard isHorizontal else {
            return CGRect(x: bounds.maxX - thickness - 2, y: rect.minY + 2,
                          width: thickness, height: max(0, rect.height - 4))
        }
        let y = isFlipped ? bounds.maxY - thickness - 2 : bounds.minY + 2
        return CGRect(x: rect.minX + 2, y: y, width: max(0, rect.width - 4), height: thickness)
    }

    /// Where the knob is now; nil while it is hidden (at rest, or nothing to scroll).
    var restingKnobFrame: CGRect? {
        guard !restingKnob.isHidden, restingKnob.alphaValue > 0 else { return nil }
        return restingKnob.convert(restingKnob.barFrame, to: self)
    }

    /// The knob is drawn now.
    public var isKnobShown: Bool { restingKnobFrame != nil }

    /// The knob is drawn wide now.
    public var isKnobExpanded: Bool { isKnobShown && drawnExpanded }

    /// The content overflows: there is a knob to drag.
    var overflows: Bool { isEnabled && knobProportion < 1 && !rect(for: .knob).isEmpty }

    override public var doubleValue: Double {
        didSet { placeKnob(animated: false) }
    }

    override public var knobProportion: CGFloat {
        didSet { placeKnob(animated: false) }
    }

    override public var isEnabled: Bool {
        didSet { placeKnob(animated: false) }
    }

    override public var frame: NSRect {
        didSet { placeKnob(animated: false) }
    }

    /// Shows the knob now and fades it out ``restDelay`` later (a scroll step, or the pointer
    /// arriving over the view).
    ///
    /// - Note: The scroll view's live scrolls call it when ``showsOnScroll`` is true.
    public func flash() {
        update { $0.scrolled() }
        armRest()
    }

    /// The one rect, in the scroll view's coordinates (the scroller's frame's space), where the
    /// pointer widens the knob and a press grabs it: the scroller's own strip at the trailing edge
    /// (a sideways scroller's: at the bottom edge). Half-open, as `CGRect.contains` is, so a pixel
    /// column is in it or not, for both.
    public var grabZone: CGRect { frame }

    /// The knob is wide with the pointer in ``grabZone``: the content overflows and the pointer there
    /// would show it (``revealsNearPointerAtRest``, or the knob already shown).
    var widensUnderPointer: Bool {
        var near = presence
        near.pointer(near: true)
        return overflows && near.expanded
    }

    /// The pointer moved over the scroll view to `point` (the scroll view's coordinates, the
    /// scroller's frame's space), or left it (nil). In ``grabZone`` it reveals and widens the knob.
    ///
    /// - Parameter point: The pointer in the scroll view's coordinates, or nil when it left the view.
    ///   The scroller's own tracking area calls it; a host that builds the scroller under the
    ///   pointer calls it once so the knob shows before the next move.
    public func pointerMoved(to point: CGPoint?) {
        let near = point.map { grabZone.contains($0) } ?? false
        guard near != presence.pointerNear else { return }
        update { $0.pointer(near: near) }
    }

    /// A press lands on the scroller in ``grabZone`` while the knob widens there, the same test as
    /// ``pointerMoved(to:)``'s: everywhere else, and at rest where the pointer does not reveal the
    /// knob, it is the content's.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && grabZone.contains(point) && widensUnderPointer ? self : nil
    }

    override public func mouseDown(with event: NSEvent) {
        update { $0.drag(true) }
        let up = track(from: event) { [weak self] mask, deadline in
            self?.window?.nextEvent(matching: mask, until: deadline, inMode: .eventTracking, dequeue: true)
        }
        update { $0.drag(false) }
        // Where the button came up decides whether the knob stays wide: the pointer may have left.
        if let superview { pointerMoved(to: superview.convert((up ?? event).locationInWindow, from: nil)) }
        armRest()
    }

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        proximity?.detach()
        proximity = nil
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        proximity = ThinScrollerProximity(scroller: self, host: superview, notificationCenter: notificationCenter)
    }

    /// Never a track, also while the pointer is over the scroller.
    override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// The knob view draws the knob: AppKit's own knob would fade on AppKit's schedule.
    override public func drawKnob() {}

    private func update(_ change: (inout ThinScrollerPresence) -> Void) {
        let before = presence
        change(&presence)
        guard presence != before else { return }
        placeKnob(animated: true)
    }

    private func armRest() {
        restTask?.cancel()
        restTask = nil
        guard presence.scrolledRecently else { return }
        let clock = clock
        // A bounded, cancellable delay that is the intended behavior (the knob's rest time after
        // the last scroll step); the next scroll cancels it. Its clock is injected.
        restTask = Task { [weak self] in
            // wakeup-allow: one-shot injected fade deadline; the next scroll cancels it.
            do { try await clock.sleep(for: Self.restDelay) } catch { return }
            self?.update { $0.rested() }
        }
    }

    private func placeKnob(animated: Bool) {
        let shows = presence.shown && overflows
        let expanded = shows && presence.expanded
        // The knob view always spans the wide knob; its bar takes the thin or the wide shape.
        let slot = knobRect(for: rect(for: .knob), expanded: true)
        drawnExpanded = expanded
        restingKnob.isHidden = false
        restingKnob.horizontal = isHorizontal
        if restingKnob.frame != slot, !slot.isEmpty { restingKnob.frame = slot }
        restingKnob.setExpanded(expanded, animated: animated)
        let alpha: CGFloat = shows ? 1 : 0
        guard restingKnob.alphaValue != alpha else { return }
        if animated {
            // A direct setter inside a timed group: the value lands now and the layer fades to it.
            Motion.feedback.animateTimed(shows ? .fadeIn : .fadeOut, in: self) { restingKnob.alphaValue = alpha }
        } else {
            restingKnob.alphaValue = alpha
        }
    }
}

/// The knob of a ``ThinScroller``: a rounded bar layer at the trailing side (a sideways knob's
/// bottom side) of a view as wide as the wide knob. The bar's width changes on its own layer (implicit actions, the ``Motion``
/// feedback gate's timing), so the new width lands at once and the layer animates to it. It lets
/// every click through to the scroller, so dragging it still scrolls.
final class ThinScrollerKnobView: NSView {
    private let bar = CALayer()
    private(set) var expanded = false
    /// A sideways scroller's knob: the bar runs along the view's bottom side.
    var horizontal = false {
        didSet { if horizontal != oldValue { updateBar(animated: false) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bar)
        updateBar(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The bar's frame in this view (its model value: the target of a running animation).
    var barFrame: CGRect { bar.frame }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var frame: NSRect {
        didSet { if frame.size != oldValue.size { updateBar(animated: false) } }
    }

    /// Draws the bar wide or thin; `animated` lets it grow or shrink over the feedback gate's
    /// movement timing (instant under Reduce Motion).
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != self.expanded else { return }
        self.expanded = expanded
        updateBar(animated: animated)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBar(animated: false)
    }

    private func updateBar(animated: Bool) {
        let thickness = expanded ? ThinScroller.expandedKnobThickness : ThinScroller.knobThickness
        let alpha = expanded ? ThinScroller.expandedKnobAlpha : ThinScroller.knobAlpha
        var color = CGColor(gray: 0.5, alpha: alpha)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
        let changes = {
            self.bar.frame = self.horizontal
                ? CGRect(x: self.bounds.minX, y: self.bounds.minY, width: self.bounds.width, height: thickness)
                : CGRect(x: self.bounds.maxX - thickness, y: self.bounds.minY,
                         width: thickness, height: self.bounds.height)
            self.bar.cornerRadius = thickness / 2
            self.bar.backgroundColor = color
        }
        if animated {
            Motion.feedback.transaction(spring: .move, in: window, changes)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}
