import AppKit
import CmuxNextDesign
import QuartzCore

/// The column strip's clip as layer structure: the strip's pane hosts sit in this
/// view, whose layer masks to its bounds, so one rect clips every strip pane whatever its spring or the
/// strip's pan does, and no host carries a mask for it. Docked columns are this view's siblings, stacked
/// above it (`ScreenContentView.rank`). Chrome clips a scroller's contents the same way: a clip node on
/// the scroller's container layer, not a mask per child (`cc/trees/clip_node.h`,
/// `ui/views/controls/scroll_view.cc` `contents_viewport_`).
///
/// A host stays in it while one of its panes zooms (no host changes parent for a zoom, so the focused
/// pane keeps its keys): the container is then lifted, its frame the whole screen and stacked above
/// the docks, and the hosts that stay under the zooming pane keep the strip's range through masks of
/// their own, set once when the zoom starts (`ScreenContentView.heldStripClip`).
///
/// Its bounds origin is its frame origin, so a host's frame here is in the screen's coordinates, as it
/// is directly in the screen: moving a host between the two keeps its frame.
///
/// It is also the strip's motion container: with `motion.renderServer` on, a strip
/// pan moves its hosts (and the strip's dividers, which then sit here too) with one property of its
/// layer, the `sublayerTransform` translation, under the fixed clip of its bounds. Not their frames,
/// and not its bounds: each of those makes AppKit recompute the visible rect, tracking areas and
/// cursor rects of every view under it, on every pan event. The rings and dims of the strip's panes
/// (the overlay plane's `StripChromePlane`, ``companion``) get the same translation in the same
/// transaction. Chrome scrolls the same way: the scroll offset is one transform node under the
/// scroller's clip node (`cc/trees/transform_node.h` `scroll_offset`), which
/// `cc/input/threaded_input_handler.cc` moves per input event; the main thread's geometry catches up
/// at its commit. ``translation`` is where the strip shows minus where its views are laid out (x,
/// points). AppKit does not know it, so pointer input never reaches a view while it shows: a press,
/// a pointer move or a new scroll gesture first lays the strip out where it shows
/// (`ScreenContentView.landStripWhereItShows()`), as Chrome targets input on committed geometry.
final class StripClipContainerView: NSView {
    /// The layer key path the pan sets and the fling springs.
    static let translationKey = RenderSpringKey<CGFloat>.sublayerTranslationX

    /// A fling on the render server: one additive spring of the translation (on this layer and on
    /// ``companion``) from `displacement` to rest, started at `velocity`. Its
    /// record solves what shows at any time with the closed form the render server runs (Chrome
    /// keeps the same record for a compositor scroll animation:
    /// `cc/animation/scroll_offset_animation_curve.cc` `GetValue`).
    struct Fling {
        var displacement: CGFloat
        var velocity: CGFloat
        var begin: CFTimeInterval
        var spring: SpringParameters
        var serial: Int
    }

    /// The strip's range (the screen's coordinates) the hosts show in: the frame, unless lifted.
    private(set) var range: CGRect = .zero
    /// True while a zoom of one of its hosts lifts the clip (`place(range:liftedTo:)`).
    private(set) var isLifted = false
    /// The translation the layer's model holds.
    private(set) var translation: CGFloat = 0
    /// The fling running on the render server, if any.
    private(set) var fling: Fling?
    /// Model translation writes, cumulative (StripPanContainerTests: one per pan event).
    private(set) var translationSets = 0
    /// The layer of the strip's rings and dims in the overlay plane (`StripChromePlane`): it takes
    /// every translation this view takes, in the same transaction, and springs with its fling.
    weak var companion: CALayer?
    /// Whether the strip shows away from where its views are laid out (a translation or a fling).
    private(set) var showsMoved = false
    /// Called when ``showsMoved`` changes: pointer input then lands the strip first
    /// (`LayoutRootView.updatePointerLanding()`).
    var onShowsMovedChange: () -> Void = {}
    private var flingSerial = 0
    /// The media clock the fling's record reads (`CACurrentMediaTime`, the render server's timebase).
    private let now: () -> CFTimeInterval

    init(frame frameRect: NSRect, now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.now = now
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // The hosts' frames are the layout's; a clip that moves resizes none of them.
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    /// Clips the hosts to `range` (the screen's coordinates), or to `lifted` (the screen's bounds) while
    /// a zoom of one of them is in flight. Returns true when the frame changed.
    @discardableResult
    func place(range: CGRect, liftedTo lifted: CGRect?) -> Bool {
        self.range = range
        isLifted = lifted != nil
        let rect = lifted ?? range
        guard frame != rect || bounds.origin != rect.origin else { return false }
        frame = rect
        setBoundsOrigin(rect.origin)
        return true
    }

    /// What shows now: the model translation plus the fling's displacement, and the fling's velocity.
    var shown: (translation: CGFloat, velocity: CGFloat) {
        guard let fling else { return (translation, 0) }
        let solved = SpringValue.solve(displacement: Double(fling.displacement), velocity: Double(fling.velocity),
                                       time: now() - fling.begin, parameters: fling.spring)
        return (translation + CGFloat(solved.displacement), CGFloat(solved.velocity))
    }

    /// The translation that shows now (``shown``).
    var shownTranslation: CGFloat { fling == nil ? translation : shown.translation }

    /// Moves the strip to `value` in this frame: one layer property, no implicit animation. Ends a
    /// fling first, where it shows.
    func setTranslation(_ value: CGFloat) {
        if fling != nil { stopFling() }
        guard value != translation else { return }
        writeModel(value)
    }

    /// Springs the strip (and ``companion``) from `displacement` (shown minus laid out) to rest on the
    /// render server, starting at `velocity` (points per second). `landed` runs once, when the fling
    /// rests; a fling ended first (``stopFling()``, a newer one) never lands. Returns false, moving
    /// nothing, when `spring` does not animate here (Reduce Motion, a display that draws no frames):
    /// the strip then shows at rest.
    @discardableResult
    func startFling(from displacement: CGFloat, velocity: CGFloat, spring: RenderSpring,
                    landed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if fling != nil { stopFling() }
        guard let layer, displacement != 0 || velocity != 0, spring.animates(Self.translationKey.path, in: self) else {
            setTranslation(0)
            return false
        }
        flingSerial += 1
        let serial = flingSerial
        let layers = [layer] + (companion.map { [$0] } ?? [])
        // Each model starts `displacement` from rest; the springs carry it back to zero.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in layers { Self.translationKey.set(displacement, on: sublayer) }
        CATransaction.commit()
        translation = 0
        translationSets += 1
        fling = Fling(displacement: displacement, velocity: velocity, begin: now(), spring: spring.parameters, serial: serial)
        let moves = layers.map { RenderSpring.Move($0, Self.translationKey, to: CGFloat(0), velocity: velocity) }
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
    func stopFling() -> (translation: CGFloat, velocity: CGFloat) {
        guard fling != nil else { return (translation, 0) }
        let shown = self.shown
        fling = nil
        if let layer { RenderSpring.stop(layer, Self.translationKey.path) }
        if let companion { RenderSpring.stop(companion, Self.translationKey.path) }
        writeModel(shown.translation)
        return shown
    }

    /// Clicks outside every host go to the screen, as they do with no container.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private func writeModel(_ value: CGFloat) {
        translation = value
        translationSets += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer { Self.translationKey.set(value, on: layer) }
        if let companion { Self.translationKey.set(value, on: companion) }
        CATransaction.commit()
        updateShowsMoved()
    }

    private func updateShowsMoved() {
        let moved = translation != 0 || fling != nil
        guard moved != showsMoved else { return }
        showsMoved = moved
        onShowsMovedChange()
    }
}
