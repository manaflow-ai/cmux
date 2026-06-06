#if canImport(UIKit)
import UIKit

/// Hosts the terminal surface (or a fallback view) edge-to-edge so it can
/// extend under the bottom safe area (home indicator) and reach the physical
/// screen bottom.
///
/// `GhosttySurfaceRepresentable` is a `UIViewControllerRepresentable` rather than
/// a `UIViewRepresentable` specifically because of this controller: SwiftUI
/// honors `.ignoresSafeArea(.container, edges: .bottom)` for a hosted view
/// *controller's* view, but leaves a bare `UIViewRepresentable`'s hosted view
/// frame clamped to the bottom safe area when it sits inside a `NavigationStack`.
/// That clamp left a ~34pt empty strip below the live terminal after the
/// keyboard hid. The content is pinned to the controller view's own edges (not
/// its safe-area guide), so when SwiftUI extends the controller view to the
/// screen edge the terminal fills it. `GhosttySurfaceView` already docks its
/// accessory bar at `bounds.height` and lets the home indicator overlay the
/// bar's lower edge, so no inner change is needed once the bounds reach bottom.
final class GhosttySurfaceHostingController: UIViewController {
    private let content: UIView

    /// Creates a controller hosting `content` edge-to-edge.
    ///
    /// - Parameter content: The view to host full-bleed (the live terminal
    ///   surface, or a runtime-failure fallback label).
    init(content: UIView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // Pin to the view's own edges, NOT the safe-area layout guide, so the
        // terminal reaches the screen bottom when SwiftUI extends this view
        // under the bottom safe area.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
#endif
