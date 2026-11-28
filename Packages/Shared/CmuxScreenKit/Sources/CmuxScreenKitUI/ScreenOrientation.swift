#if os(iOS)
import CmuxScreenKit
import UIKit

/// Applies an `OrientationLock`. iOS asks the app delegate which
/// orientations are allowed, so the app returns `shared.allowed` from
/// `application(_:supportedInterfaceOrientationsFor:)`:
///
/// ```swift
/// func application(_ application: UIApplication,
///                  supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
///     ScreenOrientation.shared.allowed
/// }
/// ```
@MainActor
public final class ScreenOrientation {
    public static let shared = ScreenOrientation()

    /// The orientations the app currently allows (all until a session locks them).
    public private(set) var allowed: UIInterfaceOrientationMask = .all

    /// Applies `lock` now, rotating if the current orientation is not allowed.
    public func lock(_ lock: OrientationLock) {
        allowed = lock.mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock.mask)) { _ in }
        }
    }
}

public extension OrientationLock {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: .all
        case .portrait: .portrait
        case .landscape: .landscape
        }
    }
}
#endif
