#if os(iOS)
import CmuxScreenKitUI
public import UIKit

/// The app is portrait everywhere but a Mac's screen, which turns with the
/// phone (or as its options menu locks it). The app delegate returns
/// ``allowed`` from `application(_:supportedInterfaceOrientationsFor:)`.
@MainActor
public final class ScreenSharingOrientation {
    public static let shared = ScreenSharingOrientation()

    /// Whether a Mac's screen is on screen.
    public private(set) var isPresenting = false

    /// Portrait, or the screen's own choice (`ScreenOrientation.shared`) while it shows.
    public var allowed: UIInterfaceOrientationMask {
        isPresenting ? ScreenOrientation.shared.allowed : .portrait
    }

    /// The screen appeared: the phone may turn.
    func begin() {
        isPresenting = true
        update(.all)
    }

    /// The screen went away: back to portrait.
    func end() {
        guard isPresenting else { return }
        isPresenting = false
        // A lock chosen in this session's menu ends with it.
        ScreenOrientation.shared.lock(.auto)
        update(.portrait)
    }

    private func update(_ mask: UIInterfaceOrientationMask) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                while let presented = controller?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = presented
                }
            }
            if mask == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
        }
    }
}
#endif
