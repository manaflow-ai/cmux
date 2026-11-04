public import AppKit

/// The views of a window that another window follows: a Chromium page window over its `CEFHostView`. The CEF fork's
/// `CmuxParentViewTracker` observes `NSViewFrameDidChangeNotification` on such a view and on every ancestor, and on each
/// notice works the page out again and moves its page window (a window server call; Chromium lays its views out for a new
/// size). A view registers itself while it is in the window (weakly held).
@MainActor
public final class FollowedViews {
    private var views: [ObjectIdentifier: Weak] = [:]
    private var holding = false

    private struct Weak {
        weak var view: NSView?
    }

    private static var associationKey: UInt8 = 0

    /// `window`'s followed views, made on first use and kept by the window.
    public static func of(_ window: NSWindow) -> FollowedViews {
        if let made = objc_getAssociatedObject(window, &associationKey) as? FollowedViews { return made }
        let made = FollowedViews()
        objc_setAssociatedObject(window, &associationKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    public func add(_ view: NSView) { views[ObjectIdentifier(view)] = Weak(view: view) }

    public func remove(_ view: NSView) { views[ObjectIdentifier(view)] = nil }

    /// Runs `apply` (a frame change of the window, which lays its tree out top-down inside it) with the frame-change
    /// notices of every followed view and its ancestors held, then lets each of those views that changed post one,
    /// deepest first: a follower sees the final geometry once per view, never the in-between places an ancestor had
    /// before the views under it were laid out (FRAME OWNER REFACTOR S7). AppKit posts the held notice when a view
    /// posts frame notices again (`postsFrameChangedNotifications`).
    public func holdingFrameNotices(_ apply: () -> Void) { // perf-hot: 4ms motion-frame
        guard !holding else { return apply() }
        var held: [NSView] = [], seen: Set<ObjectIdentifier> = []
        for entry in views.values {
            guard let followed = entry.view, let root = followed.window?.contentView else { continue }
            var view: NSView? = followed
            while let current = view, seen.insert(ObjectIdentifier(current)).inserted {
                if current.postsFrameChangedNotifications {
                    current.postsFrameChangedNotifications = false
                    held.append(current)
                }
                view = current === root ? nil : current.superview
            }
        }
        holding = true
        apply()
        holding = false
        for view in held { view.postsFrameChangedNotifications = true }
    }
}
