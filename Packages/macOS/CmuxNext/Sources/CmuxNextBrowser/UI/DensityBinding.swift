import AppKit

/// Keeps token-derived sizes live. Views register constraints and setters
/// whose values come from `BrowserMetrics`; `start()` runs them inside an
/// Observation scope, so a change to `DesignSettings.shared` (density or a
/// metric override) re-applies every value and the view re-lays out.
///
/// Closures that touch the owning view must capture it `unowned` or `weak`:
/// the view owns the binding.
final class DensityBinding {
    private var appliers: [() -> Void] = []
    private var loop: ObservationLoop?

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

    /// Applies every value now and again whenever a token it read changes.
    func start() {
        loop?.cancel()
        loop = ObservationLoop { [weak self] in
            self?.appliers.forEach { $0() }
        }
    }
}
