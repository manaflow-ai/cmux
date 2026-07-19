#if os(iOS)
import UIKit

/// Spinner-only presentation owned by the workspace list's custom refresh lifecycle.
@MainActor
final class WorkspaceListRefreshHeaderView: UIView {
    private static let minimumPullScale: CGFloat = 0.72

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isRefreshing = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        accessibilityIdentifier = "MobileWorkspaceRefreshHeader"
        backgroundColor = .clear
        isUserInteractionEnabled = false
        alpha = 0

        spinner.color = .secondaryLabel
        spinner.accessibilityIdentifier = "MobileWorkspaceRefreshIndicator"
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        spinner.transform = CGAffineTransform(
            scaleX: Self.minimumPullScale,
            y: Self.minimumPullScale
        )
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceListRefreshHeaderView does not support storyboards")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: WorkspaceListRefreshGeometry.holdHeight)
    }

    /// Reveals and scales the spinner as the user approaches the refresh threshold.
    func setPullProgress(_ progress: CGFloat) {
        guard !isRefreshing else { return }

        let clampedProgress = min(max(progress, 0), 1)
        if clampedProgress > 0, !spinner.isAnimating {
            spinner.startAnimating()
        } else if clampedProgress == 0, spinner.isAnimating {
            spinner.stopAnimating()
        }
        alpha = clampedProgress
        let scale = Self.minimumPullScale
            + (1 - Self.minimumPullScale) * clampedProgress
        spinner.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Pins the header at its fully visible, continuously spinning state.
    func beginRefreshing() {
        isRefreshing = true
        alpha = 1
        spinner.transform = .identity
        spinner.startAnimating()
    }

    /// Resets the presentation after the coordinator completes its collapse animation.
    func endRefreshing() {
        isRefreshing = false
        spinner.stopAnimating()
        alpha = 0
        spinner.transform = CGAffineTransform(
            scaleX: Self.minimumPullScale,
            y: Self.minimumPullScale
        )
    }
}
#endif
