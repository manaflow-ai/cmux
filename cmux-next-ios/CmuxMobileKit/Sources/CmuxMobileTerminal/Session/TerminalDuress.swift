// DEBUG and Demo builds only: the offline duress player is never compiled into Production.
#if DEBUG
import Foundation
#if os(iOS)
import UIKit
#endif

/// The terminal side of the offline duress simulator (cmux-next-ios/design/duress-sim.md). The
/// player (`MobileDuress`, CmuxMobileLive) installs ``attach`` once at launch when the
/// `CmuxMobileDuress` folder is set; otherwise it stays nil and nothing here runs.
@MainActor
public enum TerminalDuress {
    /// Called by every terminal page right before it starts its session. `feed` takes bytes as
    /// that session's output. The returned object keeps the playback alive; the page holds it
    /// and releases it with itself.
    public static var attach: (@MainActor (_ feed: @escaping @MainActor (Data) -> Void) -> AnyObject)?
}

#if os(iOS)
/// A real Ghostty surface nobody sees: the duress simulator's extra panes. It sits in its own
/// hidden window, out of the accessibility tree and the responder chain, and parses (and
/// renders) every byte fed to it like a terminal page's surface.
@MainActor
public final class TerminalHiddenSurface {
    private let window: UIWindow
    private let surface: TerminalSurfaceView

    public init(scene: UIWindowScene, size: CGSize) {
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = true
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        surface = TerminalSurfaceView(frame: CGRect(origin: .zero, size: size))
        surface.isAccessibilityElement = false
        // In a window: the surface makes its Ghostty surface now (`didMoveToWindow`).
        window.addSubview(surface)
    }

    public func feed(_ data: Data) { surface.feed(data) }
}
#endif
#endif
