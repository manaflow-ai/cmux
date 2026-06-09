#if os(iOS) && DEBUG
import UIKit

/// The dedicated `UIWindow` that hosts the floating DEV dogfood pane above the
/// app's scene, so the pill/overlay floats over the terminal regardless of the
/// SwiftUI view tree.
///
/// It is a passthrough window: a touch that resolves to the transparent root
/// (anywhere outside the pill or expanded pane) returns `nil` from `hitTest` so
/// the touch falls through to the app window underneath. Only the actual pane
/// controls are hittable. Without this, a full-screen overlay window would eat
/// every terminal touch.
///
/// DEBUG-only; absent in release builds.
final class DogfoodPaneWindow: UIWindow {
    /// Hit-tests so only the pane's own subviews are interactive; everything else
    /// passes through to the window below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // A hit that lands on the hosting controller's root view (the transparent
        // SwiftUI container itself, not one of the pane's interactive subviews)
        // is "empty space": let it fall through to the app window.
        if hit == rootViewController?.view {
            return nil
        }
        return hit
    }
}
#endif
