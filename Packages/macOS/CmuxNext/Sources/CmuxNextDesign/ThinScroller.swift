public import AppKit

/// The one thin scroller of cmux NEXT's native scroll views: the sidebar's list and pinned bands,
/// the Priority view and every scrollable card (hover cards, the update card's popover). Its web
/// twin is the shared page scroller (webviews/src/scrollers.ts), so the sidebar scrolls with the
/// same thumb as the chat (2026-10-21: "one shared minimal scroller style for the composer, chat
/// and sidebar").
///
/// A ``knobThickness``-wide rounded knob at the trailing edge, on no track, in the label color at
/// low contrast. It shows for as long as the content overflows (Leo 2026-10-21: "if there are
/// things to scroll, just keep the scrollbar"). With ``autoHides`` (the opt-in
/// ``SystemScrollers/thinScrollersAutoHide``) it is a plain overlay knob instead, which AppKit fades
/// in while the view scrolls and out at rest. It is always an overlay scroller, so it never takes
/// width from the content. Give a scroll view this scroller with ``SystemScrollers/followThin(_:)``;
/// never style a scroller by hand.
///
/// ```swift
/// scrollView.hasVerticalScroller = true
/// SystemScrollers.followThin(scrollView)
/// ```
public final class ThinScroller: NSScroller {
    /// The drawn knob's width, in points.
    public static let knobThickness: CGFloat = 3
    /// The scroller's width (its hit area): the knob plus a little room on each side.
    public static let width: CGFloat = 7
    /// The knob's opacity over the label color.
    static let knobAlpha: CGFloat = 0.32

    /// True fades the knob out at rest (AppKit's overlay fade); false keeps it shown while the
    /// content overflows.
    public var autoHides = false {
        didSet {
            guard autoHides != oldValue else { return }
            placeKnob()
            needsDisplay = true
        }
    }

    /// The knob that stays shown. AppKit draws an overlay scroller's own knob into a layer it fades
    /// out at rest whatever the subclass draws, so the persistent knob is a view of its own.
    let restingKnob = ThinScrollerKnobView()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(restingKnob)
        autoHides = SystemScrollers.thinScrollersAutoHide
        placeKnob()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public class var isCompatibleWithOverlayScrollers: Bool { true }

    override public class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        width
    }

    /// The knob drawn for AppKit's knob slot `rect`: its length, ``knobThickness`` wide, 2 pt in
    /// from the scroller's trailing edge (AppKit's overlay slot is narrower than the scroller and
    /// sits off its leading side).
    public func knobRect(for rect: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - Self.knobThickness - 2, y: rect.minY + 2,
               width: Self.knobThickness, height: max(0, rect.height - 4))
    }

    /// Where the resting knob is now; nil while it is hidden (auto-hide, or nothing to scroll).
    var restingKnobFrame: CGRect? { restingKnob.isHidden ? nil : restingKnob.frame }

    override public var doubleValue: Double {
        didSet { placeKnob() }
    }

    override public var knobProportion: CGFloat {
        didSet { placeKnob() }
    }

    override public var isEnabled: Bool {
        didSet { placeKnob() }
    }

    override public var frame: NSRect {
        didSet { placeKnob() }
    }

    /// Never a track, also while the pointer is over the scroller.
    override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override public func drawKnob() {
        guard autoHides else { return } // the resting knob draws it
        Self.fill(knobRect(for: rect(for: .knob)))
    }

    /// Fills the knob shape: a rounded bar in the label color, resolved for the current appearance.
    static func fill(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(knobAlpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: knobThickness / 2, yRadius: knobThickness / 2).fill()
    }

    private func placeKnob() {
        let knob = knobRect(for: rect(for: .knob))
        let shows = !autoHides && isEnabled && knobProportion < 1 && knob.height > 0
        restingKnob.isHidden = !shows
        if shows, restingKnob.frame != knob { restingKnob.frame = knob }
    }
}

/// The resting knob of a ``ThinScroller``: draws the knob shape and lets every click through to
/// the scroller, so dragging it still scrolls.
final class ThinScrollerKnobView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) { ThinScroller.fill(bounds) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
