public import AppKit

/// The views of a window that another window follows: a Chromium page window over its `CEFHostView`. The CEF fork's
/// `CmuxParentViewTracker` observes `NSViewFrameDidChangeNotification` on such a view and on every ancestor up to the
/// window's frame view, and the view's own geometry post, and on each notice works the page out again and moves its
/// page window (a window server call; Chromium lays its views out for a new size). A view registers itself while it is
/// in the window (weakly held).
@MainActor
public final class FollowedViews {
    private var views: [ObjectIdentifier: Weak] = [:]
    /// The views whose frame notices are held now (nil: no hold).
    private var heldViews: [NSView]?
    /// ``endHold()`` is letting the held notices go: AppKit posts each inside it, so their observers run then. No hold
    /// begins and no post is held until it is done.
    private var isReleasing = false
    /// The followed views' own geometry posts held now, one per view in the order they came (``holdsGeometryPost(of:_:)``).
    private var heldPosts: [HeldPost] = []

    private struct Weak {
        weak var view: NSView?
    }

    private struct HeldPost {
        weak var view: NSView?
        let post: () -> Void
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
    /// notices of every followed view and its ancestors held, and the views' own geometry posts, then lets each of those
    /// views that changed post one notice, deepest first: a follower works the step out once, with the final geometry,
    /// never at the in-between places an ancestor had before the views under it were laid out (FRAME OWNER REFACTOR S7).
    /// AppKit posts the held notice when a view posts frame notices again (`postsFrameChangedNotifications`).
    public func holdingFrameNotices(_ apply: () -> Void) { // perf-hot: 4ms motion-frame
        guard heldViews == nil else { return apply() } // held already, or the release of a hold runs `apply`
        beginHold()
        apply()
        endHold()
    }

    /// Whether the followed views' frame notices are held now (not while a hold's notices go).
    public var isHolding: Bool { heldViews != nil && !isReleasing }

    /// Holds the frame notices of every followed view and its ancestors up to the window's frame view (the follower
    /// observes all of them) until ``endHold()``. No effect while held, nor while a hold's notices go (an observer of
    /// one asks): a frame change made then posts as with no hold (a view the release has not turned on yet posts it
    /// when it does), and the caller's ``endHold()`` does nothing.
    public func beginHold() { // perf-hot: 4ms motion-frame
        guard heldViews == nil else { return }
        var held: [NSView] = [], seen: Set<ObjectIdentifier> = []
        for entry in views.values {
            guard let followed = entry.view, followed.window != nil else { continue }
            var view: NSView? = followed
            while let current = view, seen.insert(ObjectIdentifier(current)).inserted {
                if current.postsFrameChangedNotifications {
                    current.postsFrameChangedNotifications = false
                    held.append(current)
                }
                view = current.superview
            }
        }
        heldViews = held
    }

    /// While the notices are held: holds `view`'s own geometry post (`post`, which tells its follower to work the view
    /// out again) until ``endHold()`` and returns true; false (nothing held) otherwise. The layout of a window step posts
    /// from in-between places, and the follower works each followed view out after the layout anyway (the window's
    /// didResize, the frame notices let go). `post` runs at the end of the hold, after those notices: it posts only if
    /// the follower has not read the view since (the view knows its reads). One post per view is held.
    public func holdsGeometryPost(of view: NSView, _ post: @escaping () -> Void) -> Bool { // perf-hot: 1us cef-geometry
        guard isHolding else { return false }
        if !heldPosts.contains(where: { $0.view === view }) { heldPosts.append(HeldPost(view: view, post: post)) }
        return true
    }

    /// Lets the held views post again: each that changed since ``beginHold()`` posts one notice, deepest first; then
    /// the held geometry posts go. The observers of those notices run inside: until the last view posts again, a
    /// geometry post goes at once and no hold begins; the held posts go after that, each once.
    public func endHold() {
        guard let held = heldViews, !isReleasing else { return }
        isReleasing = true
        for view in held { view.postsFrameChangedNotifications = true }
        heldViews = nil
        isReleasing = false
        let posts = heldPosts
        heldPosts = []
        for held in posts { held.post() }
    }
}
