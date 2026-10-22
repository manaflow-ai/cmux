#if os(iOS)
import UIKit

/// T-SCROLL-12: in a full-screen app (the alternate screen) a vertical drag
/// scrolls the app, like a Mac trackpad in Ghostty, and the page stays
/// pinned. The drag and its fling become wheel events on the surface
/// (`TerminalTUIScroll`, `TerminalTUIMomentum`); Ghostty turns them into
/// what the app asked for. A tap still focuses the terminal, a long press
/// still selects and a selection handle still moves: this pan starts only
/// on a vertical drag that no selection gesture owns. A new touch stops a
/// fling, as on a trackpad.
@MainActor
final class TerminalTUIScrollController: NSObject, @MainActor UIGestureRecognizerDelegate {
    /// The app is on the alternate screen and the surface is in the TUI host.
    var isEnabled: () -> Bool = { false }
    /// A selection gesture owns the touch (a long press, a handle).
    var selectionOwns: (UITouch?) -> Bool = { _ in false }
    /// A drag began scrolling the app (its content moves under any selection).
    var dragBegan: () -> Void = {}

    private weak var surface: TerminalSurfaceView?
    private(set) var pan: UIPanGestureRecognizer?
    private var scroll = TerminalTUIScroll()
    private var momentum: TerminalTUIMomentum?
    private var momentumAt = CGPoint.zero
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0

    func install(in host: UIView, surface: TerminalSurfaceView) {
        self.surface = surface
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        host.addGestureRecognizer(pan)
        self.pan = pan
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let surface else { return }
        let at = pan.location(in: surface)
        switch pan.state {
        case .began:
            stopMomentum()
            scroll.began()
            dragBegan()
            send(scroll.moved(translationY: pan.translation(in: surface).y), at: at)
        case .changed:
            send(scroll.moved(translationY: pan.translation(in: surface).y), at: at)
        case .ended:
            send(scroll.moved(translationY: pan.translation(in: surface).y), at: at)
            if isEnabled(), let fling = TerminalTUIMomentum(velocityY: pan.velocity(in: surface).y) {
                startMomentum(fling, at: at)
            }
        default:
            break
        }
    }

    private func send(_ wheel: TerminalTUIScroll.Wheel?, at point: CGPoint) {
        guard let wheel, let surface, isEnabled() else { return }
        surface.scrollWheel(at: point, deltaY: wheel.dy, momentum: wheel.momentum)
    }

    private func startMomentum(_ fling: TerminalTUIMomentum, at point: CGPoint) {
        momentum = fling
        momentumAt = point
        lastStep = 0
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        guard var fling = momentum, isEnabled() else { return stopMomentum() }
        let dt = lastStep == 0 ? link.duration : link.timestamp - lastStep
        lastStep = link.timestamp
        let wheel = fling.step(dt: dt)
        momentum = fling
        send(wheel, at: momentumAt)
        if fling.isFinished { endLink() }
    }

    /// A touch, a new drag or leaving the app stops a fling (its end goes out once).
    func stopMomentum() {
        if var fling = momentum {
            let end = fling.stop()
            momentum = nil
            send(end, at: momentumAt)
        }
        endLink()
    }

    private func endLink() {
        momentum = nil
        link?.invalidate()
        link = nil
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A finger on the screen stops the fling, like a trackpad.
        stopMomentum()
        return isEnabled() && !selectionOwns(touch)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, isEnabled(), !selectionOwns(nil) else { return false }
        return TerminalTUIScroll.takesDrag(velocity: pan.velocity(in: pan.view))
    }
}
#endif
