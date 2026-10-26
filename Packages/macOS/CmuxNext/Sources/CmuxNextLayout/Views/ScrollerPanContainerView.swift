import AppKit
import QuartzCore

/// A view that shows its subviews moved by a layer translation their frames do not carry: the strip
/// container (`StripClipContainerView`) and the container of a row column or scroll area
/// (``ScrollerPanContainerView``). A host shows at its frame plus the translations of these ancestors
/// (`ScreenContentView.panTranslation(of:)`); its frame stays where it was laid out.
@MainActor
protocol PanMotionContainer: NSView {
    /// The translation the layer's model holds (points, this view's axes).
    var panTranslation: CGVector { get }
    /// The translation that shows now: the model's, plus a fling the render server runs.
    var shownPanTranslation: CGVector { get }
    /// Whether the layer clips its subviews to its bounds.
    var clipsSubviews: Bool { get }
}

extension StripClipContainerView: PanMotionContainer {
    var panTranslation: CGVector { CGVector(dx: translation, dy: 0) }
    var shownPanTranslation: CGVector { CGVector(dx: shownTranslation, dy: 0) }
    var clipsSubviews: Bool { true }
}

/// The motion container of one of the strip's nested scrollers (p04-input-050, behind
/// `motion.renderServer`): a column whose rows overflow, or a horizontal scroll area. Its pane hosts and
/// dividers sit in it, and its rows' or cells' rings and dims sit in ``chromePlane`` in the overlay
/// plane; a pan event of the scroller sets the translation of the two layers' `sublayerTransform` and
/// nothing else, as the strip container does for a strip pan (p03-rendering-026). A scroll area's
/// container also clips its hosts to the area's window, one rect for every host of the area, so no
/// host carries a mask for it. Chrome gives each nested scroller its own transform node under its own
/// clip node (`cc/trees/transform_node.h` `scroll_offset`, `cc/trees/clip_node.h`), moved per input event
/// by `cc/input/threaded_input_handler.cc`.
///
/// Its bounds origin is its frame origin, so a host's frame here is in the screen's coordinates, as it
/// is in the strip container: moving a host between the two keeps its frame. AppKit does not know the
/// translation, so pointer input never reaches a view while it shows one: a press, a pointer move, a new
/// gesture or a wheel notch first lays the scroller out where it shows
/// (`ScreenContentView.landStripWhereItShows()`).
final class ScrollerPanContainerView: NSView, PanMotionContainer {
    /// The scroller a container moves.
    nonisolated enum Scroller: Hashable, Sendable {
        /// The rows of a strip column whose rows overflow it (vertical).
        case row(ColumnID)
        /// A horizontal scroll area, by its root split.
        case area(SplitID)

        var isArea: Bool {
            if case .area = self { return true }
            return false
        }
    }

    let scroller: Scroller
    /// The rings and dims of this scroller's panes: a plane inside the strip's (`StripChromePlane`), or
    /// inside its row's when an area sits in a scrolling row. It takes every translation this view takes.
    let chromePlane = StripChromePlane(frame: .zero)
    /// The translation the layer's model holds.
    private(set) var translation: CGVector = .zero
    /// Model translation writes, cumulative (RowScrollTests: one per pan event).
    private(set) var translationSets = 0
    /// Whether the scroller shows away from where its views are laid out.
    private(set) var showsMoved = false
    /// Called when ``showsMoved`` changes: pointer input then lands the scroller first.
    var onShowsMovedChange: () -> Void = {}
    /// What the clip covers of the hosts, as last placed (`ScreenContentView.placeScrollerContainers`): a
    /// page in an area's pane re-reads its clip shape only when it changes, not when the strip or the row
    /// moves the container and its hosts together.
    var placedClip: PlacedClip?

    /// The clip relative to the hosts: the window's size, the offset they are laid out at in it, and
    /// whether it clips.
    struct PlacedClip: Hashable {
        var size: CGSize
        var offset: CGFloat
        var clips: Bool
    }

    init(scroller: Scroller) {
        self.scroller = scroller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // The hosts' frames are the layout's; a container that moves resizes none of them.
        autoresizesSubviews = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    var panTranslation: CGVector { translation }
    var shownPanTranslation: CGVector { translation }
    var clipsSubviews: Bool { layer?.masksToBounds ?? false }

    /// Places the container over `rect` (its superview's coordinates, the screen's) with its bounds
    /// origin there too. Returns true when the frame changed.
    @discardableResult
    func place(_ rect: CGRect) -> Bool {
        guard frame != rect || bounds.origin != rect.origin else { return false }
        frame = rect
        setBoundsOrigin(rect.origin)
        return true
    }

    /// Clips the hosts to the bounds (a scroll area's window) or not. Returns true when it changed.
    @discardableResult
    func setClips(_ clips: Bool) -> Bool {
        guard let layer, layer.masksToBounds != clips else { return false }
        layer.masksToBounds = clips
        return true
    }

    /// Moves the scroller's views and their rings to `value` in this frame: one property of each of the
    /// two layers, no implicit animation.
    func setTranslation(_ value: CGVector) {
        guard value != translation else { return }
        translation = value
        translationSets += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.setSublayerTranslation(value, of: self)
        Self.setSublayerTranslation(value, of: chromePlane)
        CATransaction.commit()
        let moved = value != .zero
        guard moved != showsMoved else { return }
        showsMoved = moved
        onShowsMovedChange()
    }

    /// Sets `view`'s layer `sublayerTransform` to the translation `value` (the view's own axes), mapped to
    /// the layer's axes (`RenderLayerAxes`: a flipped view's y runs the other way in its layer).
    private static func setSublayerTranslation(_ value: CGVector, of view: NSView) {
        guard let layer = view.layer else { return }
        let axes = RenderLayerAxes(view)
        layer.sublayerTransform = CATransform3DMakeTranslation(value.dx * axes.x, value.dy * axes.y, 0)
    }

    /// Clicks outside every host go to the screen, as they do with no container.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
