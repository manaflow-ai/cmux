import AppKit
import CmuxNextWakeups
import Observation

/// Keeps token-derived sizes live. Views register constraints and setters
/// whose values come from `BrowserMetrics`; `start(in:)` runs them inside an
/// Observation scope, so a change to `DesignSettings.shared` (density or a
/// metric override) re-applies every value and the view re-lays out.
///
/// The re-apply runs once at the next frame of the view's window
/// (`FrameScheduler.forView`), however many tokens changed: Blink's style
/// recalc at the next BeginMainFrame. An occluded window applies when its
/// link runs again. Leaf controls own this binding, and no scheduler reaches
/// them, so it is a window frame client, not a ``FrameObservation``.
///
/// Closures that touch the owning view must capture it `unowned` or `weak`:
/// the view owns the binding.
final class DensityBinding {
    private var appliers: [() -> Void] = []
    private var frame: FrameClient?

    /// Registers `constraint` so its constant always equals `value()`.
    @discardableResult
    func bind(_ constraint: NSLayoutConstraint, _ value: @escaping () -> CGFloat) -> NSLayoutConstraint {
        constraint.constant = value()
        appliers.append { constraint.constant = value() }
        return constraint
    }

    /// Registers a setter (fonts, radii, spacing) that reads tokens.
    func update(_ apply: @escaping () -> Void) {
        appliers.append(apply)
    }

    /// Applies every value now, as a token change does (tests: a density
    /// change without writing the app-wide `DesignSettings.shared`).
    func reapply() {
        appliers.forEach { $0() }
    }

    /// Applies every value now, and again at the next frame of `view`'s
    /// window after a token it read changes.
    func start(in view: NSView) {
        frame?.deactivate()
        // UI rate: nothing follows the pointer.
        // frame-client: a token change re-applies AppKit constraints and fonts at the next frame (one tick, on main)
        frame = FrameClient(owner: "browser.density", isAnimation: false, rate: .ui, scheduler: { [weak view] in
            view.map { FrameScheduler.forView($0) } ?? FrameScheduler.app
        }) { [weak self] _ in
            self?.applyTracked()
            return false
        }
        applyTracked()
    }

    private func applyTracked() {
        // view-observation-allow: design tokens in leaf controls with no scheduler; a change re-applies at the window's next frame
        withObservationTracking {
            appliers.forEach { $0() }
        } onChange: { @Sendable [weak self] in
            // main-hop-allow: tokens change on main, so this runs inline in the change's turn and only asks for a frame
            MainDelivery().run { [weak self] in self?.frame?.activate() }
        }
    }
}
