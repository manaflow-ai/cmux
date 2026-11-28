#if os(iOS)
import UIKit

/// Regions where a horizontal drag belongs to the control under it, never to
/// the navigation back swipe (design/terminal R4-1): the terminal's key bar
/// scrolls and its joystick drags sideways, so a rightward swipe that starts
/// there must not pop the workspace. Screens register the views; the pop
/// gesture's delegate asks before it begins.
@MainActor
public final class NavigationPopExclusion {
    public static let shared = NavigationPopExclusion()

    private var views: [WeakView] = []

    private struct WeakView { weak var view: UIView? }

    public init() {}

    public func exclude(_ view: UIView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakView(view: view))
    }

    /// Whether a drag that started at `point` (in `window`) is in an excluded,
    /// visible region.
    public func excludes(_ point: CGPoint, in window: UIWindow?) -> Bool {
        guard let window else { return false }
        views.removeAll { $0.view == nil }
        for entry in views {
            guard let view = entry.view, view.window === window, !view.isHidden, view.alpha > 0.01,
                  view.bounds.height > 1 else { continue }
            if view.convert(view.bounds, to: window).contains(point) { return true }
        }
        return false
    }

    /// The start of a pan that has already travelled (UIKit asks a pop
    /// recognizer once the finger moved past its slop).
    public static func startPoint(of recognizer: UIGestureRecognizer, in window: UIWindow?) -> CGPoint {
        let now = recognizer.location(in: window)
        guard let pan = recognizer as? UIPanGestureRecognizer else { return now }
        let moved = pan.translation(in: window)
        return CGPoint(x: now.x - moved.x, y: now.y - moved.y)
    }
}
#endif
