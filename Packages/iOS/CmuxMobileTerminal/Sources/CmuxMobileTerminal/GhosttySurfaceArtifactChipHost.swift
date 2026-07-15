#if canImport(UIKit)
import UIKit

/// Owns the terminal artifact chip's UIKit container, sizing, and transition state.
@MainActor
final class GhosttySurfaceArtifactChipHost {
    private let container = UIView()
    private(set) var isRequestedVisible = false
    private var visibilityRequested = false

    func install(in surfaceView: UIView, zPosition: CGFloat) {
        container.backgroundColor = .clear
        container.clipsToBounds = false
        container.alpha = 0
        container.isHidden = true
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        container.layer.zPosition = zPosition
        surfaceView.addSubview(container)
    }

    func setContent(_ view: UIView?) {
        isRequestedVisible = view != nil
        guard let view, container.subviews.first !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }

    // Anchored to the terminal's top edge: pinned above the toolbar it covered
    // the input row, which users type into far more often than they read the
    // first terminal line.
    func layout(in bounds: CGRect, topInset: CGFloat) {
        guard let content = container.subviews.first else {
            container.frame = .zero
            return
        }
        let maxWidth = max(44, bounds.width - 32)
        let fitting = content.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        let width = min(maxWidth, max(88, fitting.width))
        let height = max(44, fitting.height)
        container.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(8, topInset + 8),
            width: width,
            height: height
        ).integral
        content.frame = container.bounds
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
