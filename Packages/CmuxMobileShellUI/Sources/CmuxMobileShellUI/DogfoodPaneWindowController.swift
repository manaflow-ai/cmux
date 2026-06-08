#if os(iOS) && DEBUG
import CmuxMobileShell
import SwiftUI
import UIKit

/// Owns the floating dogfood pane's ``DogfoodPaneWindow`` for one `UIWindowScene`.
///
/// Built lazily when the host representable first resolves its window scene (the
/// scene is not connected at launch), retained by the representable's coordinator
/// so the window is not deallocated. The window sits one level above the app's
/// normal windows and hosts the ``DogfoodPaneOverlayView`` bound to the injected
/// ``DogfoodFeedbackModel``.
///
/// DEBUG-only; absent in release builds.
@MainActor
final class DogfoodPaneWindowController {
    private let window: DogfoodPaneWindow

    /// Creates and shows the overlay window for a scene.
    /// - Parameters:
    ///   - scene: The window scene to float above.
    ///   - model: The pane model the overlay binds to.
    init(scene: UIWindowScene, model: DogfoodFeedbackModel) {
        let window = DogfoodPaneWindow(windowScene: scene)
        // One level above `.normal` so it floats over the app content but below
        // system alerts. It is a passthrough window, so it never blocks the app.
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = UIHostingController(rootView: DogfoodPaneOverlayView(model: model))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    /// Tear the window down (scene disconnect). Detaching the root controller and
    /// hiding the window drops it from the scene.
    func teardown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
#endif
