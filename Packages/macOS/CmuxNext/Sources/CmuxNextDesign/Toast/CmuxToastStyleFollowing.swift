/// A view that draws a toast outside the toast center (the browser page's notice) and takes a new pick
/// at once: ``CmuxToastStyleStore/follow(_:)`` holds it weakly and calls it on every pick.
@MainActor
public protocol CmuxToastStyleFollowing: AnyObject {
    /// The person picked `style`: draw in it now.
    func toastStyleDidChange(_ style: CmuxToastStyle)
}
