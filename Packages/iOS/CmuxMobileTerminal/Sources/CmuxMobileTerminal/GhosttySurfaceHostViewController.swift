#if canImport(UIKit)
import UIKit

/// Gives the terminal an explicit UIKit size-transition lifecycle. SwiftUI can
/// lay out a UIViewRepresentable after the new orientation's bounds arrive,
/// which is too late to fence an alternate-screen resize.
public final class GhosttySurfaceHostViewController: UIViewController {
    public let hostView: GhosttySurfaceHostView

    public init(hostView: GhosttySurfaceHostView) {
        self.hostView = hostView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func loadView() {
        view = hostView
    }

    public override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        hostView.beginInterfaceTransition(coordinator)
        super.viewWillTransition(to: size, with: coordinator)
    }
}
#endif
