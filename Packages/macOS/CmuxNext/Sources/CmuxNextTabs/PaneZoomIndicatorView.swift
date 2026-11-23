public import AppKit
import CmuxNextDesign

/// A zoomed pane's indicator (Cmd-Shift-Return, Toggle Pane Zoom) for a pane whose tab bar shows no
/// controls (a pane with them shows it in their trailing slot, `PaneToolbarView.zoomButton`): a small Exit Zoom
/// button at the pane's top-right corner, over the content just under the tab bar, as Ghostty draws a zoomed
/// split's (user 2026-11-07: "should show up in top right of pane rather than in the tab itself").
/// It sits on the shared overlay glass, like the find pill, so it reads over any terminal or page;
/// the glyph is lit like the pane's other zoom marks. It shows while its strip's model says the
/// pane is zoomed (``TabStripModel/zoomsSelected``), and a click sends the strip's
/// ``TabStripIntent/toggleZoom(_:)``, the tab double-click's and Cmd-Shift-Return's one path. Only
/// the button takes clicks; the glass rim passes them to the content.
///
/// ```swift
/// let indicator = PaneZoomIndicatorView(model: stripModel)
/// pane.addSubview(indicator)
/// // in the pane's layout(): the width it takes from the corner (0 while hidden)
/// let taken = indicator.place(in: contentFrame, top: contentTop)
/// ```
public final class PaneZoomIndicatorView: NSView {
    /// The glyph: the collapse arrows, what a click does.
    public static let symbol = "arrow.down.right.and.arrow.up.left"
    /// The glass's padding around the button.
    static let padding: CGFloat = 2

    let button = TitlebarBandButton(symbol: PaneZoomIndicatorView.symbol)
    /// The glass, made when the indicator first shows: every pane holds a hidden indicator, and a
    /// hidden zero-size `NSGlassEffectView` still lays out its SwiftUI host on every frame of a pane
    /// motion on macOS 27 (`KeyResizeLayoutsPerFrameTests`).
    private var surface: OverlaySurfaceView?
    private weak var model: TabStripModel?

    /// - Parameter model: The pane's strip model: its zoom shows the indicator, its selection is
    ///   what a click's intent names.
    public init(model: TabStripModel) {
        self.model = model
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(pressed)
        button.refusesFirstResponder = true
        button.setAccessibilityLabel(Strings.exitZoom)
        button.themedToolTip = Strings.exitZoom
        addSubview(button)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }

    /// The indicator's size: the tab bar's icon button on a thin rim of glass.
    public static var size: NSSize {
        let side = TitlebarBandButton.side + 2 * padding
        return NSSize(width: side, height: side)
    }

    /// Shows the indicator while the model's pane is zoomed, at `content`'s top-right with its top at
    /// `top` (both in the superview's coordinates); returns the width it takes from that corner, 0
    /// while hidden.
    ///
    /// - Parameter elsewhere: the pane's tab bar shows the zoom in its trailing controls
    ///   (`PaneToolbarView.zoomButton`): the corner stays empty.
    @discardableResult
    public func place(in content: NSRect, top: CGFloat, elsewhere: Bool = false) -> CGFloat {
        isHidden = elsewhere || model?.zoomsSelected != true
        guard !isHidden else { return 0 }
        if surface == nil {
            let glass = Glass.makeOverlayPanel(cornerRadius: Metrics.buttonCornerRadius + Self.padding, tone: .neutralGlass(.transient))
            glass.translatesAutoresizingMaskIntoConstraints = true
            glass.autoresizingMask = [.width, .height]
            addSubview(glass, positioned: .below, relativeTo: button)
            surface = glass
        }
        let inset = Metrics.space2
        let size = Self.size
        frame = NSRect(x: content.maxX - inset - size.width, y: top + inset, width: size.width, height: size.height)
        return size.width + inset
    }

    /// Only the button takes the pointer; the glass rim passes it to the content.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit === button || hit.isDescendant(of: button) else { return nil }
        return hit
    }

    /// The button's frame in an indicator with `bounds`: the bounds less the glass's padding. Nil
    /// when the bounds have no room for it (a hidden indicator has no size): the inset of a rect
    /// smaller than the inset is the null rect, whose origin is infinite. AppKit does not keep that
    /// frame: the button lands far outside its pane.
    static func buttonFrame(in bounds: NSRect) -> NSRect? {
        let frame = bounds.insetBy(dx: padding, dy: padding)
        return frame.isNull ? nil : frame
    }

    override public func layout() {
        super.layout()
        // No room for the button: the frames wait for a size.
        if let frame = Self.buttonFrame(in: bounds) {
            surface?.frame = bounds
            button.frame = frame
        }
        button.layer?.cornerRadius = Metrics.buttonCornerRadius
        button.contentTintColor = performWithTheme { Palette.litGlyph }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// The layout that shows the pane has it zoomed, or has it not (`PaneContentChrome.setPaneShownZoomed`): the
    /// pane's zoom marks take it now. The strip's model gets the zoom (``TabStripModel/zoomsSelected``), the pane lays
    /// out again (it places this indicator, and its strip gives up the trailing controls' width), and `controls`
    /// applies the pane's state again in this call: its own observation of the model runs a turn later.
    public func show(zoomed: Bool, controls: (any PaneControlsRefreshing)?) {
        guard let model, model.zoomsSelected != zoomed else { return }
        model.zoomsSelected = zoomed
        superview?.needsLayout = true
        controls?.refresh()
    }

    @objc private func pressed() {
        guard let model, let id = model.selectedID ?? model.tabs.first?.id else { return }
        model.send(.toggleZoom(id))
    }
}

/// The owner of a pane's trailing controls (the App's `PaneToolbar`): it applies the pane's state to them again, now.
@MainActor
public protocol PaneControlsRefreshing: AnyObject {
    /// Applies the pane's state to the controls again.
    func refresh()
}
