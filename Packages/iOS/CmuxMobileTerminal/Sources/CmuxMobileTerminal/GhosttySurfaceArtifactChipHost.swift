#if canImport(UIKit)
import UIKit

/// Owns the terminal artifact chip's UIKit container, sizing, and transition state.
///
/// The container is constraint-anchored to the top of whichever view hosts
/// it. `GhosttySurfaceView` installs it into itself at init (standalone
/// surfaces, tests); `GhosttySurfaceHostView` re-homes it — the same adoption
/// ``GhosttySurfaceView/moveBottomDock(to:)`` performs for the dock — so the
/// chip lives in the host's keyboard-invariant chrome coordinate space. The
/// keyboard slides the render wrapper, never the chrome, so the chip needs no
/// keyboard math and no per-frame following: its position falls out of the
/// same layout solve that seats the dock.
@MainActor
final class GhosttySurfaceArtifactChipHost {
    private let container = UIView()
    private(set) var isRequestedVisible = false
    private var visibilityRequested = false
    private weak var hostView: UIView?
    private var anchorConstraints: [NSLayoutConstraint] = []
    private var contentConstraints: [NSLayoutConstraint] = []

    /// Anchored to the top of the host's safe area: pinned above the toolbar
    /// it covered the input row, which users type into far more often than
    /// they read the first terminal line.
    ///
    /// Idempotent re-homing: installing into a new host replaces the previous
    /// anchor constraints. Re-homing happens only at host construction,
    /// before any chip is mounted, so the reset of the hidden/alpha state
    /// never blinks a visible chip.
    func install(in hostView: UIView, zPosition: CGFloat) {
        guard hostView !== self.hostView else { return }
        container.backgroundColor = .clear
        container.clipsToBounds = false
        container.alpha = 0
        container.isHidden = true
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        container.layer.zPosition = zPosition
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(anchorConstraints)
        container.removeFromSuperview()
        hostView.addSubview(container)
        self.hostView = hostView
        // Tap-target floor and readable-width ceiling, matching the manual
        // frame pass this container had before it was constraint-anchored.
        // The weak default-size pulls sit below every content priority so a
        // hosted view's intrinsic size drives the container between the
        // floor and ceiling, while content without an intrinsic size (bare
        // test views) still resolves unambiguously to the floor.
        let defaultWidth = container.widthAnchor.constraint(equalToConstant: 88)
        defaultWidth.priority = UILayoutPriority(100)
        let defaultHeight = container.heightAnchor.constraint(equalToConstant: 44)
        defaultHeight.priority = UILayoutPriority(100)
        anchorConstraints = [
            container.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
            container.topAnchor.constraint(
                equalTo: hostView.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            container.widthAnchor.constraint(
                lessThanOrEqualTo: hostView.widthAnchor,
                constant: -32
            ),
            defaultWidth,
            defaultHeight,
        ]
        NSLayoutConstraint.activate(anchorConstraints)
    }

    func setContent(_ view: UIView?) {
        isRequestedVisible = view != nil
        guard let view, container.subviews.first !== view else { return }
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
        container.subviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        // Edge-pinned so the hosted view's intrinsic size drives the
        // container between the anchor floor/ceiling constraints.
        contentConstraints = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentConstraints)
    }

    func updateVisibility(shouldShow: Bool, animated: Bool) {
        visibilityRequested = shouldShow
        if shouldShow {
            container.isHidden = false
            container.accessibilityElementsHidden = false
            let changes = { [weak self] in
                self?.container.alpha = 1
                self?.container.transform = .identity
            }
            if animated {
                if container.alpha < 0.01 {
                    container.transform = CGAffineTransform(translationX: 0, y: -8)
                }
                UIView.animate(
                    withDuration: 0.2,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction],
                    animations: changes
                )
            } else {
                changes()
            }
            return
        }

        guard !container.isHidden else { return }
        container.accessibilityElementsHidden = true
        let changes = { [weak self] in
            self?.container.alpha = 0
            self?.container.transform = CGAffineTransform(translationX: 0, y: -8)
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, !self.visibilityRequested else { return }
            self.container.isHidden = true
        }
        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes,
                completion: completion
            )
        } else {
            changes()
            completion(true)
        }
    }

    func contains(_ view: UIView) -> Bool {
        !container.isHidden && view.isDescendant(of: container)
    }
}
#endif
