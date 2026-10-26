import AppKit
import CmuxNextDesign
import QuartzCore

/// The column strip's motion container (p03-rendering-026): with `motion.renderServer` on, the strip's
/// pane hosts and dividers sit in this view, and a strip pan moves all of them with one property of
/// its layer, the `sublayerTransform` translation. Not their frames, and not this view's bounds: each
/// of those makes AppKit recompute the visible rect, tracking areas and cursor rects of every view
/// under it, on every pan event. Chrome scrolls the same way: the scroll offset is one transform node
/// over the scrolled contents (`cc/trees/transform_node.h` `scroll_offset`), which
/// `cc/input/threaded_input_handler.cc` moves per input event, and the main thread's geometry
/// catches up at its commit.
///
/// The frame is the screen's bounds and the bounds origin zero, so a subview's frame is in the
/// screen's coordinates. ``translation`` is where the strip shows minus where its views are laid
/// out (x, points). AppKit does not know it: hit testing here applies it (``hitTest(_:)``), and a
/// reader of a subview's geometry adds it (``ScreenContentView/placedFrame(of:)``).
final class StripPanContainerView: NSView {
    /// The layer key path the pan sets and the fling springs.
    static let translationKeyPath = "sublayerTransform.translation.x"

    /// A fling on the render server: one additive spring of the translation (and of the overlay
    /// layers that show with the strip) from `displacement` to rest, started with `velocity`.
    /// Its record solves what shows at any time with the closed form the render server runs
    /// (Chrome keeps the same record for a compositor scroll animation:
    /// `cc/animation/scroll_offset_animation_curve.cc` `GetValue`).
    struct Fling {
        var displacement: CGFloat
        var velocity: CGFloat
        var begin: CFTimeInterval
        var spring: SpringParameters
        /// The layers it springs: this view's (on ``translationKeyPath``), then the overlay layers
        /// (on `position.x`).
        var layers: [CALayer]
        var serial: Int
    }

    /// The translation the layer's model holds.
    private(set) var translation: CGFloat = 0
    /// The fling running on the render server, if any.
    private(set) var fling: Fling?
    /// Model translation writes, cumulative (StripPanContainerTests: one per pan event).
    private(set) var translationSets = 0
    private var flingSerial = 0
    /// The media clock the fling's record reads (`CACurrentMediaTime`, the render server's timebase).
    private let now: () -> CFTimeInterval

    init(now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.now = now
        super.init(frame: .zero)
        wantsLayer = true
        // The screen lays the hosts out: a container resize moves none of them.
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

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

    /// Springs the strip from `displacement` (shown minus laid out) to rest on the render server,
    /// starting at `velocity` (points per second), with `chrome`, the layers outside this view that
    /// show with the strip (pane rings and dims), on the same spring from the same begin time.
    /// `landed` runs once, when the fling rests; a fling ended first (``stopFling()``, a newer one)
    /// never lands. Returns false, moving nothing, when `spring` does not animate here (Reduce Motion,
    /// a display that draws no frames): the strip then shows at rest.
    @discardableResult
    func startFling(from displacement: CGFloat, velocity: CGFloat, spring: RenderSpring, with chrome: [CALayer],
                    landed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if fling != nil { stopFling() }
        guard let layer, displacement != 0 || velocity != 0, spring.animates(Self.translationKeyPath, in: self) else {
            setTranslation(0)
            return false
        }
        flingSerial += 1
        let serial = flingSerial
        let rests = chrome.map(\.position.x)
        // Each model starts `displacement` from where it rests; the springs carry it back to zero.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(NSNumber(value: Double(displacement)), forKeyPath: Self.translationKeyPath)
        for (sublayer, rest) in zip(chrome, rests) { sublayer.position.x = rest + displacement }
        CATransaction.commit()
        translation = 0
        translationSets += 1
        var moves = [RenderSpring.Move(layer, Self.translationKeyPath, to: CGFloat(0), velocity: velocity)]
        for (sublayer, rest) in zip(chrome, rests) { moves.append(RenderSpring.Move(sublayer, "position.x", to: rest, velocity: velocity)) }
        fling = Fling(displacement: displacement, velocity: velocity, begin: now(), spring: spring.parameters,
                      layers: [layer] + chrome, serial: serial)
        spring.animateGroup(moves, in: self) { [weak self] finished in
            guard let self, finished, self.fling?.serial == serial else { return }
            self.fling = nil
            landed()
        }
        return true
    }

    /// Ends the fling where it shows: the model takes the shown translation, so nothing moves on
    /// screen, and the overlay layers show their models (their next sync places them). Returns what
    /// showed, with its velocity.
    @discardableResult
    func stopFling() -> (translation: CGFloat, velocity: CGFloat) {
        guard let fling else { return (translation, 0) }
        let shown = self.shown
        self.fling = nil
        for sublayer in fling.layers {
            RenderSpring.stop(sublayer, sublayer === layer ? Self.translationKeyPath : "position.x")
        }
        writeModel(shown.translation)
        return shown
    }

    /// `windowPoint` in the window's coordinates, moved to where the strip's views are laid out: a
    /// subview's own `convert(_:from: nil)` of the result is the point over it on screen.
    func laidOutWindowPoint(_ windowPoint: NSPoint) -> NSPoint {
        NSPoint(x: windowPoint.x - shownTranslation, y: windowPoint.y)
    }

    /// Hits the subview that shows under `point` (the superview's coordinates): the point moved by
    /// the translation that shows, a fling's included. A point between the views goes to the screen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let laidOut = NSPoint(x: local.x - shownTranslation, y: local.y)
        for view in subviews.reversed() where !view.isHidden {
            if let hit = view.hitTest(laidOut) { return hit }
        }
        return nil
    }

    private func writeModel(_ value: CGFloat) {
        translation = value
        translationSets += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setValue(NSNumber(value: Double(value)), forKeyPath: Self.translationKeyPath)
        CATransaction.commit()
    }
}
