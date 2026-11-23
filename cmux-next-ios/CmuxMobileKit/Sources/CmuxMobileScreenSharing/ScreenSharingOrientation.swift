#if os(iOS)
import CmuxMobileLinkFFI
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

    /// Whether a window this size is an unfolded foldable's: Rust's
    /// `window_layout` (its `UNFOLDED_SHORT_SIDE`, 600 pt), the same rule that
    /// gives the shell two panes, so orientation and layout never disagree.
    public nonisolated static func isUnfolded(windowSize size: CGSize) -> Bool {
        windowLayout(width: Double(size.width), height: Double(size.height)).unfolded
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
