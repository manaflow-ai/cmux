import AppKit
import CmuxNextDesign
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

/// The motion container of one of the strip's nested scrollers (behind
/// `motion.renderServer`): a column whose rows overflow, or a horizontal scroll area. Its pane hosts and
/// dividers sit in it, and its rows' or cells' rings and dims sit in ``chromePlane`` in the overlay
/// plane; a pan event of the scroller sets the translation of the two layers' `sublayerTransform` and
/// nothing else, as the strip container does for a strip pan, and the fling after it
/// is a render-server spring of that translation along the scroller's axis. A scroll area's
/// container also clips its hosts to the area's window, one rect for every host of the area, so no
/// host carries a mask for it. Chrome gives each nested scroller its own transform node under its own
/// clip node (`cc/trees/transform_node.h` `scroll_offset`, `cc/trees/clip_node.h`), moved per input event
/// by `cc/input/threaded_input_handler.cc`, and flings it as a compositor animation
/// (`cc/input/scroll_offset_animations_impl.h`).
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
    /// The fling running on the render server, if any: one spring along the scroller's axis, recorded as
    /// the strip's is (`StripClipContainerView.Fling`).
    private(set) var fling: StripClipContainerView.Fling?
    /// Model translation writes, cumulative (RowScrollTests: one per pan event).
    private(set) var translationSets = 0
    /// Whether the scroller shows away from where its views are laid out (a translation or a fling).
    private(set) var showsMoved = false
    /// Called when ``showsMoved`` changes: pointer input then lands the scroller first.
    var onShowsMovedChange: () -> Void = {}
    /// What the clip covers of the hosts, as last placed (`ScreenContentView.placeScrollerContainers`): a
    /// page in an area's pane re-reads its clip shape only when it changes, not when the strip or the row
    /// moves the container and its hosts together.
    var placedClip: PlacedClip?
    private var flingSerial = 0
    /// The media clock the fling's record reads (`CACurrentMediaTime`, the render server's timebase).
    private let now: () -> CFTimeInterval

    /// The clip relative to the hosts: the window's size, the offset they are laid out at in it, and
    /// whether it clips.
    struct PlacedClip: Hashable {
        var size: CGSize
        var offset: CGFloat
        var clips: Bool
    }

    init(scroller: Scroller, now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.scroller = scroller
        self.now = now
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
    var shownPanTranslation: CGVector { fling == nil ? translation : shown.translation }
    var clipsSubviews: Bool { layer?.masksToBounds ?? false }

    /// The layer key the scroller's axis moves on: x for a scroll area, y for rows.
    var axisKey: RenderSpringKey<CGFloat> { scroller.isArea ? .sublayerTranslationX : .sublayerTranslationY }

    /// The layer key path the scroller's axis moves on: x for a scroll area, y for rows.
    var axisKeyPath: String { axisKey.path }

    /// `vector`'s component along the scroller's axis.
    func alongAxis(_ vector: CGVector) -> CGFloat { scroller.isArea ? vector.dx : vector.dy }

    /// A translation of `value` along the scroller's axis.
    func onAxis(_ value: CGFloat) -> CGVector { scroller.isArea ? CGVector(dx: value, dy: 0) : CGVector(dx: 0, dy: value) }

    /// The two views whose layers take every translation and fling: this one and its rings' plane.
    private var layers: [NSView] { [self, chromePlane] }

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

    /// What shows now: the model translation plus the fling's displacement, and the fling's velocity.
    var shown: (translation: CGVector, velocity: CGVector) {
        guard let fling else { return (translation, .zero) }
        let solved = SpringValue.solve(displacement: Double(fling.displacement), velocity: Double(fling.velocity),
                                       time: now() - fling.begin, parameters: fling.spring)
        let moved = onAxis(CGFloat(solved.displacement))
        return (CGVector(dx: translation.dx + moved.dx, dy: translation.dy + moved.dy), onAxis(CGFloat(solved.velocity)))
    }

    /// Moves the scroller's views and their rings to `value` in this frame: one property of each of the
    /// two layers, no implicit animation. Ends a fling first, where it shows.
    func setTranslation(_ value: CGVector) {
        if fling != nil { stopFling() }
        guard value != translation else { return }
        writeModel(value)
    }

    /// Springs the scroller's views and their rings from `displacement` (shown minus laid out, along its
    /// axis) to rest on the render server, starting at `velocity` (points per second), as the strip's
    /// fling does (`StripClipContainerView.startFling`). `landed` runs once, when the fling rests; a fling
    /// ended first (``stopFling()``, a newer one) never lands. Returns false, moving nothing, when `spring`
    /// does not animate here: the scroller then shows at rest.
    @discardableResult
    func startFling(from displacement: CGFloat, velocity: CGFloat, spring: RenderSpring,
                    landed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if fling != nil { stopFling() }
        let key = axisKey
        let keyPath = key.path
        guard displacement != 0 || velocity != 0, spring.animates(keyPath, in: self) else {
            setTranslation(.zero)
            return false
        }
        flingSerial += 1
        let serial = flingSerial
        // Each model starts `displacement` from rest; the springs carry it back to zero.
        writeModel(onAxis(displacement))
        translation = .zero
        fling = StripClipContainerView.Fling(displacement: displacement, velocity: velocity, begin: now(),
                                             spring: spring.parameters, serial: serial)
        let area = scroller.isArea
        let moves = layers.compactMap { view -> RenderSpring.Move? in
            guard let layer = view.layer else { return nil }
            return RenderSpring.Move(layer, key, to: CGFloat(0), velocity: velocity * Self.axisSign(of: view, area: area))
        }
        spring.animateGroup(moves, in: self) { [weak self] finished in
            guard let self, finished, self.fling?.serial == serial else { return }
            self.fling = nil
            self.updateShowsMoved()
            landed()
        }
        updateShowsMoved()
        return true
    }

    /// Ends the fling where it shows: the model takes the shown translation, so nothing moves on
    /// screen. Returns what showed, with its velocity.
    @discardableResult
    func stopFling() -> (translation: CGVector, velocity: CGVector) {
        guard fling != nil else { return (translation, .zero) }
        let shown = self.shown
        fling = nil
        for view in layers {
            if let layer = view.layer { RenderSpring.stop(layer, axisKeyPath) }
        }
        writeModel(shown.translation)
        return shown
    }

    /// Clicks outside every host go to the screen, as they do with no container.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private func writeModel(_ value: CGVector) {
        translation = value
        translationSets += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.setSublayerTranslation(value, of: self)
        Self.setSublayerTranslation(value, of: chromePlane)
        CATransaction.commit()
        updateShowsMoved()
    }

    private func updateShowsMoved() {
        let moved = translation != .zero || fling != nil
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

    /// The sign of the scroller's axis in `view`'s layer (`RenderLayerAxes`).
    private static func axisSign(of view: NSView, area: Bool) -> CGFloat {
        let axes = RenderLayerAxes(view)
        return area ? axes.x : axes.y
    }
}
