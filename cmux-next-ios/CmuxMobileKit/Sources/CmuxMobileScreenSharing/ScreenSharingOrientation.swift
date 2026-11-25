#if os(iOS)
import CmuxScreenKitUI
public import UIKit

/// The app is portrait on a phone's screen everywhere but a Mac's screen,
/// which turns with the phone (or as its options menu locks it). An unfolded
/// foldable's wide, nearly square screen ("iPhone Duo") turns everywhere, as
/// an iPad's does: people hold it either way. The app delegate returns
/// ``allowed(in:)`` from `application(_:supportedInterfaceOrientationsFor:)`.
@MainActor
public final class ScreenSharingOrientation {
    public static let shared = ScreenSharingOrientation()

    /// A window whose shorter side is at least this is an unfolded foldable's.
    /// No shipping iPhone's shorter side reaches it (the largest is 440 pt); an
    /// unfolded foldable's is about 670 pt.
    nonisolated static let unfoldedShortSide: CGFloat = 600

    /// Whether a Mac's screen is on screen.
    public private(set) var isPresenting = false

    /// The screen's own choice (`ScreenOrientation.shared`) while a Mac's screen
    /// shows, else the window's resting orientations.
    public func allowed(in window: UIWindow?) -> UIInterfaceOrientationMask {
        isPresenting ? ScreenOrientation.shared.allowed : Self.resting(windowSize: Self.size(of: window))
    }

    /// The window's size, or its scene's when the system asks with no window.
    private static func size(of window: UIWindow?) -> CGSize {
        if let window { return window.bounds.size }
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
    }

    /// Portrait on a phone's screen; any orientation but upside down (as the
    /// Info.plist lists) on an unfolded foldable's.
    nonisolated static func resting(windowSize size: CGSize) -> UIInterfaceOrientationMask {
        isUnfolded(windowSize: size) ? .allButUpsideDown : .portrait
    }

    public nonisolated static func isUnfolded(windowSize size: CGSize) -> Bool {
        min(size.width, size.height) >= unfoldedShortSide
    }

    /// The window crossed between a phone's size and an unfolded foldable's: a
    /// fold turns the app back to portrait, an unfold lets it turn.
    public func foldChanged() {
        update()
    }

    /// The screen appeared: the phone may turn.
    func begin() {
        isPresenting = true
        update()
    }

    /// The screen went away: back to the window's resting orientations.
    func end() {
        guard isPresenting else { return }
        isPresenting = false
        // A lock chosen in this session's menu ends with it.
        ScreenOrientation.shared.lock(.auto)
        update()
    }

    private func update() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                while let presented = controller?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = presented
                }
            }
            if !isPresenting, Self.resting(windowSize: scene.effectiveGeometry.coordinateSpace.bounds.size) == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}
#endif
