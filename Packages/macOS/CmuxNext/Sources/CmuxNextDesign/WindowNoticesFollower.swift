/// An object that follows one window's notices through that window's ``WindowNotices``.
///
/// The window's ``WindowNotices`` holds each follower weakly, so a follower needs no `deinit` work to
/// leave: when it is released, it drops out of the window's list. A view-side type conforms and
/// calls ``WindowNotices/add(_:for:)`` when it starts following a window and
/// ``WindowNotices/remove(_:)`` when it stops or moves to another window.
///
/// ```swift
/// extension WindowMainObserver: WindowNoticesFollower {
///     func windowNoticed(_ notice: WindowNotice) {
///         changed(isMain: notice == .becameMain)
///     }
/// }
/// ```
@MainActor
public protocol WindowNoticesFollower: AnyObject {
    /// Called on the main actor for each notice of the followed window that this follower asked for.
    ///
    /// - Parameter notice: The notice the window posted.
    func windowNoticed(_ notice: WindowNotice)
}
