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
/// - The pointer within ``nearDistance`` of the trailing edge shows it and widens it from
///   ``knobThickness`` to ``expandedKnobThickness``; it stays wide while it is dragged. For a
///   sideways scroller that edge is the bottom one.
/// - It takes clicks only on the drawn knob, so a row's trailing button stays reachable.
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
    /// The scroller's width: the wide knob plus 2 pt on each side.
    public static let width: CGFloat = 11
    /// How close to the scroll view's trailing edge the pointer reveals and widens the knob.
    public static let nearDistance: CGFloat = 20
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

    /// True: the pointer near the edge reveals a hidden knob. False (the terminal, whose last
    /// column belongs to the terminal): the pointer only holds and widens a knob already shown.
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

    private var overflows: Bool { isEnabled && knobProportion < 1 && !rect(for: .knob).isEmpty }

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

    /// The pointer moved over the scroll view to `point` (the scroll view's coordinates, the
    /// scroller's frame's space), or left it (nil). Near the trailing edge (a sideways scroller's
    /// bottom edge) reveals and widens the knob.
    func pointerMoved(to point: CGPoint?) {
        let near: Bool = {
            guard let point else { return false }
            guard isHorizontal else {
                return point.x >= frame.maxX - Self.nearDistance && point.x <= frame.maxX + 1
                    && point.y >= frame.minY && point.y <= frame.maxY
            }
            guard point.x >= frame.minX, point.x <= frame.maxX else { return false }
            // The bar sits on the scroll view's bottom edge, which is maxY in a flipped scroll view.
            return superview?.isFlipped == true
                ? point.y <= frame.maxY + 1 && point.y >= frame.maxY - Self.nearDistance
                : point.y >= frame.minY - 1 && point.y <= frame.minY + Self.nearDistance
        }()
        guard near != presence.pointerNear else { return }
        update { $0.pointer(near: near) }
    }

    /// Clicks land on the scroller only on the drawn knob (its wide shape, 2 pt of slack around it).
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard restingKnobFrame != nil, let superview else { return nil }
        let local = convert(point, from: superview)
        let target = knobRect(for: rect(for: .knob), expanded: true).insetBy(dx: -2, dy: -2)
        return target.contains(local) ? self : nil
    }

    override public func mouseDown(with event: NSEvent) {
        update { $0.drag(true) }
        super.mouseDown(with: event) // tracks the knob until the button comes up
        update { $0.drag(false) }
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
            Motion.feedback.transaction(spring: .move, changes)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}
