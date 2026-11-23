/// Where a request to show a workspace came from (`WindowManager.show(workspaceID:in:from:)`).
public enum ShowOrigin: Equatable, Sendable {
    /// A person's gesture inside the window asked (its sidebar): the workspace shows there.
    case thisWindow
    /// Anything else (a notification, a link, the CLI): the window that lists the workspace shows it.
    case anywhere

    /// After `show`'s claim left the workspace in another window: whether that window comes forward. A sidebar pick
    /// raises only a window its claim opened, never another open one, which may be on another macOS Space (cmux#37371).
    public func raisesOwner(ownerWasOpen: Bool) -> Bool { self == .anywhere || !ownerWasOpen }
}
