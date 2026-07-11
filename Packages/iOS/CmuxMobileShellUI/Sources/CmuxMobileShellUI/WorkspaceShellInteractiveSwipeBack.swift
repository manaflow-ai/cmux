import SwiftUI
#if os(iOS)
@preconcurrency import UIKit

/// Re-enables the interactive swipe-from-edge back gesture, which UIKit disables
/// whenever a custom leading bar button replaces the system back button.
struct InteractiveSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        InteractiveSwipeBackGestureHostController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
