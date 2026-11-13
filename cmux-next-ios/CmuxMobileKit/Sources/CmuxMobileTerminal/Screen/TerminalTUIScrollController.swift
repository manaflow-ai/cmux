#if os(iOS)
import UIKit

/// T-SCROLL-12: in a full-screen app (the alternate screen) a vertical drag
/// scrolls the app, like a Mac trackpad in Ghostty, and the page stays
/// pinned. The drag and its fling become wheel events on the surface
/// (`TerminalTUIScroll`, `TerminalTUIMomentum`), which reach the app as
/// wheel reports it asked for, or as one cursor key per whole row for a
/// pager or an editor (`TerminalPanRoute`), else not at all. A tap still focuses the terminal, a long press
/// still selects and a selection handle still moves: this pan starts only
/// on a vertical drag that no selection gesture owns. A new touch stops a
/// fling, as on a trackpad, and a tap that stops one does nothing else (it
/// does not focus the terminal). The wheel stays at the cell where the drag
/// began, like the pointer during a trackpad scroll.
@MainActor
final class TerminalTUIScrollController: NSObject, @MainActor UIGestureRecognizerDelegate {
    /// The app is on the alternate screen and the surface is in the TUI host.
    var isEnabled: () -> Bool = { false }
    /// A selection gesture owns the touch (a long press, a handle).
    var selectionOwns: (UITouch?) -> Bool = { _ in false }
    /// A drag began scrolling the app (its content moves under any selection).
    var dragBegan: () -> Void = {}
    /// A drag began: the screen reads the foreground program again, so the
    /// route follows a program started since the last one.
    var routeMayHaveChanged: () -> Void = {}

    private weak var surface: TerminalSurfaceView?
    private(set) var pan: UIPanGestureRecognizer?
    private var scroll = TerminalTUIScroll()
    private var momentum: TerminalTUIMomentum?
    /// The whole rows of this drag and its fling (``TerminalPanRoute/cursorKeys``).
    private var rows = TerminalAlternateScroll.Rows()
    /// While the screen reads the foreground program (``routeMayHaveChanged``),
    /// the drag's movement so far and its release speed: replayed by
    /// ``programRead()`` once the program is known, so a drag in less loses
    /// nothing to the round trip. Nil when no read is out.
    private var held: (dy: CGFloat, release: CGFloat?)?
    /// Where the drag began: every wheel of the drag and its fling is there.
    private var anchor = CGPoint.zero
    /// The touch that stopped a fling (the terminal's tap ignores it).
    private weak var flingStopTouch: UITouch?
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    /// Whether the host's tap is the app's click (``TerminalTUITapClick``).
    private var tapClick = TerminalTUITapClick()
    private weak var tap: UITapGestureRecognizer?
    /// Where and when the tap's finger landed (host points, the touch clock).
    private var tapDown: (at: CGPoint, time: TimeInterval)?

    /// `tap`: the host's tap, which a touch that stops a fling does not reach.
    func install(in host: UIView, surface: TerminalSurfaceView, tap: UITapGestureRecognizer) {
        self.surface = surface
        self.tap = tap
        tap.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        host.addGestureRecognizer(pan)
        // A touch that becomes a drag is never also a tap.
        tap.require(toFail: pan)
        self.pan = pan
    }

    /// What the host's tap, recognized at `location` (host points), does.
    func tapVerdict(at location: CGPoint) -> TerminalTUITapClick.Verdict {
        guard let tapDown else { return .focusOnly }
        let moved = hypot(location.x - tapDown.at.x, location.y - tapDown.at.y)
        return tapClick.verdict(downAt: tapDown.time, upAt: CACurrentMediaTime(), moved: moved)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let surface else { return }
        switch pan.state {
        case .began:
            stopMomentum()
            scroll.began()
            rows.began()
            dragBegan()
            held = (0, nil)
            routeMayHaveChanged()
            // The finger's start, not where the pan recognized.
            let translation = pan.translation(in: surface)
            let at = pan.location(in: surface)
            anchor = CGPoint(x: at.x - translation.x, y: at.y - translation.y)
            // The touch slop before the pan began is not scaled: a drag
            // meant to be slow starts fast past it.
            send(scroll.moved(translationY: translation.y))
        case .changed:
            send(scroll.moved(translationY: pan.translation(in: surface).y, velocityY: pan.velocity(in: surface).y))
        case .ended:
            send(scroll.moved(translationY: pan.translation(in: surface).y, velocityY: pan.velocity(in: surface).y))
            if held != nil {
                // The route is not known yet: the fling waits for it too.
                held?.release = pan.velocity(in: surface).y
            } else if isEnabled(), surface.panRoute.reachesApp,
               let fling = TerminalTUIMomentum(velocityY: pan.velocity(in: surface).y) {
                startMomentum(fling)
            }
        default:
            break
        }
    }

    /// The screen read the foreground program (or gave up): the drag held
    /// while it was out goes to the app if the route now reaches it, and its
    /// fling starts. A drag that sends nothing anyway drops what it held.
    func programRead() {
        guard let hold = held else { return }
        held = nil
        guard let surface, isEnabled(), surface.panRoute.reachesApp else { return }
        if hold.dy != 0 { send(TerminalTUIScroll.Wheel(dy: hold.dy, momentum: .none)) }
        if let release = hold.release, let fling = TerminalTUIMomentum(velocityY: release) {
            startMomentum(fling)
        }
    }

    private func send(_ wheel: TerminalTUIScroll.Wheel?) {
        guard let wheel, let surface, isEnabled() else { return }
        // Wheel reports never wait (that route does not depend on the
        // program); anything else waits for the program while it is read.
        if held != nil, surface.panRoute != .wheelReports {
            held?.dy += wheel.dy
            return
        }
        // Only a wheel the app got makes it scroll (TerminalPanRoute).
        if surface.dragWheel(wheel, at: anchor, rows: &rows) {
            tapClick.scrolled(at: CACurrentMediaTime())
        }
    }

    private func startMomentum(_ fling: TerminalTUIMomentum) {
        momentum = fling
        lastStep = 0
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        guard var fling = momentum, isEnabled() else { return stopMomentum() }
        let dt = lastStep == 0 ? link.duration : link.timestamp - lastStep
        lastStep = link.timestamp
        let wheel = fling.step(dt: dt)
        momentum = fling
        send(wheel)
        if fling.isFinished { endLink() }
    }

    /// A touch, a new drag or leaving the app stops a fling (its end goes out once).
    func stopMomentum() {
        if var fling = momentum {
            let end = fling.stop()
            momentum = nil
            send(end)
        }
        endLink()
    }

    private func endLink() {
        momentum = nil
        link?.invalidate()
        link = nil
    }

    // MARK: UIGestureRecognizerDelegate

    // The pan's delegate, and the host tap's (`install`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A finger on the screen stops the fling, like a trackpad; both
        // recognizers see the touch, in either order.
        if momentum != nil {
            stopMomentum()
            flingStopTouch = touch
        }
        guard gestureRecognizer === pan else {
            if gestureRecognizer === tap, let view = gestureRecognizer.view {
                tapDown = (touch.location(in: view), touch.timestamp)
            }
            return touch !== flingStopTouch
        }
        return isEnabled() && !selectionOwns(touch)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard isEnabled(), !selectionOwns(nil) else { return false }
        // The translation so far (a slow drag can report no velocity yet).
        let moved = pan.translation(in: pan.view)
        return TerminalTUIScroll.takesDrag(motion: moved == .zero ? pan.velocity(in: pan.view) : moved)
    }
}
#endif
